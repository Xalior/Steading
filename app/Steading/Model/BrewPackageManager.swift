import Foundation
import Observation

/// UI-facing brew model for the Brew Package Manager window. Owns the
/// unified package index loaded from brew's internal JWS index + the
/// Steading-owned tap cache, the sidebar mode + its filters, per-row
/// marking state, the batched Apply pipeline (add phase before remove
/// phase, with a post-uninstall autoremove confirmation), and the
/// pin/unpin verbs. Reads the upgradable subset from
/// `BrewUpdateManager` so the headless cycle stays the single source
/// of truth for `brew outdated`.
@Observable
@MainActor
final class BrewPackageManager {

    // MARK: - Public types

    enum State: Equatable, Sendable {
        case idle
        case loading
        case applying
        case failed(message: String)
    }

    /// Outcome of the most recent Apply, kept on the manager so the
    /// progress area can display a success/failure/cancel indicator
    /// after the pipeline finishes.
    enum ApplyOutcome: Equatable, Sendable {
        case success
        case failed(exitCode: Int32)
        case cancelled
        case spawnFailed(reason: String)
    }

    enum SidebarMode: Sendable, Hashable {
        case status
        case origin
        case searchResults
    }

    /// Status mode's four mutually-exclusive view filters. Selecting
    /// `pinned` shows only pinned formulae regardless of installed/
    /// upgradable state — same single-key constraint as the others.
    enum StatusFilter: Sendable, Hashable, CaseIterable {
        case installed
        case notInstalled
        case upgradable
        case pinned
    }

    /// Verb derived from a row's package state at the moment Apply
    /// runs. Uniformly applied: each marked row contributes exactly
    /// one verb, the row's bare checkbox carries the user's intent.
    enum Verb: Sendable, Equatable {
        case install
        case upgrade
        case remove
    }

    /// One package row. Combines the universe entry with current
    /// per-host status. Identifiable on `fullToken` so SwiftUI lists
    /// can diff stably across refreshes.
    struct PackageRow: Sendable, Hashable, Identifiable {
        let entry: BrewIndexEntry
        let isInstalled: Bool
        let isOutdated: Bool
        let isPinned: Bool
        var id: String { entry.fullToken }
    }

    /// Argv breakdown for one Apply run. Each non-empty list becomes
    /// a brew sub-call in order; empty lists skip their phase.
    struct ApplyArgv: Sendable, Equatable {
        let upgrades: [String]
        let installs: [String]
        let removes: [String]
        var isEmpty: Bool {
            upgrades.isEmpty && installs.isEmpty && removes.isEmpty
        }
    }

    /// Enablement decisions for the toolbar. Pure — derived from
    /// state and counts.
    struct Buttons: Equatable, Sendable {
        let applyEnabled: Bool
        let checkNowEnabled: Bool
        let markAllEnabled: Bool
        let perRowEnabled: Bool
        let cancelEnabled: Bool
    }

    // MARK: - Pure helpers

    /// Verb a marked row's checkbox implies, given its current state.
    nonisolated static func verb(for row: PackageRow) -> Verb {
        if !row.isInstalled { return .install }
        if row.isOutdated { return .upgrade }
        return .remove
    }

    /// Split the marked rows into the three argv tails the Apply
    /// pipeline runs. Order within each list mirrors input order.
    nonisolated static func applyArgv(for rows: [PackageRow]) -> ApplyArgv {
        var upgrades: [String] = []
        var installs: [String] = []
        var removes: [String] = []
        for row in rows {
            let token = row.entry.fullToken
            switch verb(for: row) {
            case .upgrade: upgrades.append(token)
            case .install: installs.append(token)
            case .remove:  removes.append(token)
            }
        }
        return ApplyArgv(upgrades: upgrades, installs: installs, removes: removes)
    }

    /// Toolbar enablement table. Mirrors the prior
    /// `BrewUpdateManager.buttons(...)` shape with the new manager's
    /// state values; relocation-equivalent so the view's call site
    /// reads identically after the narrowing.
    nonisolated static func buttons(state: State,
                                    markedCount: Int,
                                    upgradableCount: Int) -> Buttons {
        let isApplying = state == .applying
        let isLoading = state == .loading
        let busy = isApplying || isLoading
        return Buttons(
            applyEnabled:    !busy && markedCount > 0,
            checkNowEnabled: !busy,
            markAllEnabled:  !busy && upgradableCount > 0,
            perRowEnabled:   !isApplying,
            cancelEnabled:   isApplying
        )
    }

    /// Status-mode predicate: does a row match the selected filter?
    nonisolated static func matches(_ row: PackageRow, statusFilter: StatusFilter) -> Bool {
        switch statusFilter {
        case .installed:    return row.isInstalled
        case .notInstalled: return !row.isInstalled
        case .upgradable:   return row.isOutdated
        case .pinned:       return row.isPinned
        }
    }

    /// Origin-mode predicate: does a row originate from the named tap?
    nonisolated static func matches(_ row: PackageRow, originTap tap: String) -> Bool {
        row.entry.tap == tap
    }

    /// Search-results predicate: case-insensitive substring match
    /// against name + `desc`, mirroring `brew search --desc`. The
    /// fully-qualified token is also matched so a user typing a tap
    /// prefix surfaces tap-namespaced packages.
    nonisolated static func matches(_ row: PackageRow, search needle: String) -> Bool {
        matches(row, searchLowered: needle.lowercased())
    }

    /// Same predicate, but with a pre-lowercased needle — used by the
    /// filtered-rows pipeline so the needle isn't re-lowercased once
    /// per row at filter time (k+ rows × per-row .lowercased()
    /// dominates type-ahead latency without this).
    nonisolated static func matches(_ row: PackageRow, searchLowered lowered: String) -> Bool {
        if lowered.isEmpty { return false }
        if row.entry.token.lowercased().contains(lowered) { return true }
        if row.entry.fullToken.lowercased().contains(lowered) { return true }
        if let desc = row.entry.desc?.lowercased(), desc.contains(lowered) { return true }
        return false
    }

    /// The trailing slice of the Apply log to publish for display. A
    /// big `brew upgrade` streams megabytes; rendering all of it in a
    /// selectable monospaced `Text` re-lays-out the whole string on
    /// every update and saturates the main thread, so we show only the
    /// last `maxCharacters`, trimmed forward to the next newline so the
    /// first visible line isn't chopped mid-token. Logs at or under the
    /// cap are returned unchanged.
    nonisolated static func displayTail(_ log: String, maxCharacters: Int = 16_000) -> String {
        guard log.count > maxCharacters else { return log }
        let start = log.index(log.endIndex, offsetBy: -maxCharacters)
        let tail = log[start...]
        if let newline = tail.firstIndex(of: "\n") {
            return String(tail[tail.index(after: newline)...])
        }
        return String(tail)
    }

    // MARK: - Observable state

    /// Manager-level state. `idle` is the resting state once the
    /// initial index load has completed; `applying` is set while a
    /// brew sub-call (upgrade / install / uninstall / autoremove) is
    /// in flight; `loading` covers the index-refresh cycle; `failed`
    /// surfaces an index-load failure to the view.
    private(set) var state: State = .loading

    /// Universe of packages, keyed and ordered by `fullToken`.
    private(set) var rows: [PackageRow] = []

    /// Sidebar mode. Forced to `.searchResults` while `searchText` is
    /// non-empty (the view's search affordance).
    var sidebarMode: SidebarMode = .status

    /// Currently-selected Status mode filter.
    var statusFilter: StatusFilter = .upgradable

    /// Currently-selected tap (Origin mode). `nil` when nothing is
    /// selected — the view shows an empty list.
    var originTap: String?

    /// User-typed search text. Switching this from empty to non-empty
    /// flips `sidebarMode` to `.searchResults`; switching back to
    /// empty is the user's job (Search Results is sticky once
    /// entered, matching Synaptic's behaviour).
    var searchText: String = ""

    /// Set of marked row IDs (full tokens). Mutated through
    /// `mark(_:_:)` / `markAll(...)` / `unmarkAll()`.
    private(set) var marked: Set<String> = []

    /// Streaming output from the in-flight Apply, UTF-8 decoded in
    /// arrival order — the *displayed* slice: a bounded tail published
    /// at a throttled rate (see `appendApplyOutput`). The view renders
    /// this as one selectable monospaced `Text`, so it must stay small
    /// and change infrequently or SwiftUI re-lays-out the whole string
    /// on every brew chunk and pins the main thread. Reset at the start
    /// of each Apply.
    private(set) var applyLog: String = ""

    /// Full accumulated Apply output, not observed — brew emits a
    /// torrent of small chunks (and `\r` progress redraws) and we must
    /// not invalidate the view on each one. `appendApplyOutput` buffers
    /// here and flushes a bounded tail into `applyLog` on a ~10 Hz
    /// timer, collapsing hundreds of per-chunk renders into a handful.
    @ObservationIgnored private var applyLogBuffer: String = ""

    /// True while a coalesced flush of `applyLogBuffer` → `applyLog` is
    /// already pending, so a burst of chunks schedules exactly one.
    @ObservationIgnored private var applyLogFlushScheduled = false

    /// Outcome of the most recent Apply. `nil` until the first Apply
    /// completes; cleared at the start of each fresh Apply.
    private(set) var recentApplyOutcome: ApplyOutcome?

    /// True while the Apply pipeline is paused on the post-uninstall
    /// autoremove confirmation. The view shows the dialog while this
    /// is true; pressing Yes/No calls `confirmAutoremove(_:)`.
    private(set) var pendingAutoremoveConfirmation: Bool = false

    /// Window scene id that launched the in-flight (or just-finished)
    /// job. The shared apply modal is presented only from this window,
    /// so two windows never fight to show the same dialog. `nil` once
    /// no job is active and any result has been dismissed.
    private(set) var ownerWindowID: String?

    /// Installed taps in display order, refreshed alongside the index.
    private(set) var taps: [BrewTapInfo] = []

    /// Window scene ids that can own a brew job, so triggers and the
    /// presentation gates agree on the same constants.
    nonisolated static let mainWindowID = "main"
    nonisolated static let packageManagerWindowID = "brew-package-manager"

    // MARK: - DI seams

    /// One streaming brew sub-call. Spawns a process, yields output
    /// pieces as they arrive, and concludes with one terminal event
    /// carrying the [ApplyOutcome].
    enum SubCallEvent: Sendable, Equatable {
        case output(String)
        case finished(ApplyOutcome)
    }

    /// Handle returned by a sub-call spawn. The events stream ends
    /// after exactly one terminal `.finished` event. `cancel` sends
    /// the underlying process the same SIGTERM → SIGKILL sequence
    /// `StreamingProcessRunner.Handle.cancel` does.
    struct SubCallHandle: Sendable {
        let events: AsyncStream<SubCallEvent>
        let cancel: @Sendable () -> Void
    }

    /// Dependency boundary for the Apply pipeline's per-sub-call
    /// spawn. Production wraps `StreamingProcessRunner` with the
    /// brew path and the bundled askpass helper; tests inject a
    /// closure that emits canned events to drive the state machine.
    typealias SubCallRunner = @Sendable (_ argv: [String]) -> SubCallHandle

    /// Reused from `BrewUpdateManager`: the one-shot subprocess
    /// surface. Drives pin / unpin / index-loader spawns, which
    /// don't need streaming output.
    typealias Runner = BrewUpdateManager.Runner

    /// Resolves the on-disk path for brew 6's consolidated internal
    /// package index (`api/internal/packages.<tag>.jws.json`). Returns
    /// `nil` when the file is unavailable — the loader treats that as
    /// "no entries from this source", not an error.
    typealias PackagesIndexPathResolver = @Sendable () -> URL?

    /// Resolves the on-disk path for the Steading-owned tap-cache
    /// file (`~/Library/Caches/com.xalior.Steading/tap-index.json`).
    /// Reuses `BrewUpdateManager`'s alias so both managers point at
    /// the same file by default.
    typealias TapIndexCachePathResolver = BrewUpdateManager.TapIndexCachePathResolver

    /// Synchronous file reader. Production reads the file's bytes
    /// off disk; tests inject a closure that returns canned data.
    typealias DataReader = @Sendable (URL) throws -> Data

    // MARK: - Lifecycle

    private let runner: Runner
    private let subCallRunner: SubCallRunner
    private let packagesIndexPathResolver: PackagesIndexPathResolver
    private let tapIndexCachePathResolver: TapIndexCachePathResolver
    private let dataReader: DataReader
    private var applyTask: Task<Void, Never>?
    private var inflightHandle: SubCallHandle?
    private var autoremoveContinuation: CheckedContinuation<Bool, Never>?
    /// Monotonic counter incremented on every `refresh(outdated:)`
    /// call. The in-flight loader records its own generation and
    /// only writes back to `rows` / `taps` if it's still the latest;
    /// a stale loader (one whose `outdated` has been superseded by
    /// a newer call) finishes silently. This is the SwiftUI
    /// `.task(id:)` re-entry contract — the second fire must always
    /// reflect the new id, never get coalesced into the first.
    private var refreshGeneration: Int = 0

    init(runner: @escaping Runner = BrewUpdateManager.defaultRunner,
         subCallRunner: @escaping SubCallRunner = BrewPackageManager.defaultSubCallRunner(),
         packagesIndexPathResolver: @escaping PackagesIndexPathResolver = BrewPackageManager.defaultPackagesIndexPathResolver,
         tapIndexCachePathResolver: @escaping TapIndexCachePathResolver = BrewUpdateManager.defaultTapIndexCachePathResolver,
         dataReader: @escaping DataReader = BrewPackageManager.defaultDataReader) {
        self.runner = runner
        self.subCallRunner = subCallRunner
        self.packagesIndexPathResolver = packagesIndexPathResolver
        self.tapIndexCachePathResolver = tapIndexCachePathResolver
        self.dataReader = dataReader
        self.state = .idle
    }

    // MARK: - Pin / unpin

    /// Most recent pin/unpin error, surfaced to the view. `nil`
    /// either means the last verb succeeded or none has been
    /// attempted this session.
    private(set) var lastPinError: String?

    /// Argv for `brew pin <name>`. Pure — exposed for tests.
    nonisolated static func pinArgv(for token: String) -> [String] {
        ["pin", token]
    }

    /// Argv for `brew unpin <name>`. Pure — exposed for tests.
    nonisolated static func unpinArgv(for token: String) -> [String] {
        ["unpin", token]
    }

    /// Pin a formula. No-op if the row is missing or already pinned;
    /// the row's `isPinned` flips on a zero-exit `brew pin`.
    func pin(_ token: String) {
        runPinVerb(argv: Self.pinArgv(for: token), token: token, expectedPinned: true)
    }

    /// Unpin a formula. Mirrors `pin` for the inverse verb.
    func unpin(_ token: String) {
        runPinVerb(argv: Self.unpinArgv(for: token), token: token, expectedPinned: false)
    }

    private func runPinVerb(argv: [String], token: String, expectedPinned: Bool) {
        let verbName = argv.first ?? "pin"
        Task { [weak self, runner] in
            let result = await runner(argv)
            await self?.applyPinResult(result, token: token,
                                       verbName: verbName,
                                       expectedPinned: expectedPinned)
        }
    }

    private func applyPinResult(_ result: BrewUpdateManager.RunResult,
                                token: String,
                                verbName: String,
                                expectedPinned: Bool) {
        switch result {
        case .ran(let exit, _, _) where exit == 0:
            if let i = rows.firstIndex(where: { $0.id == token }) {
                let r = rows[i]
                rows[i] = PackageRow(
                    entry: r.entry,
                    isInstalled: r.isInstalled,
                    isOutdated: r.isOutdated,
                    isPinned: expectedPinned
                )
            }
            lastPinError = nil
        case .ran(let exit, _, let stderr):
            let message = String(data: stderr, encoding: .utf8) ?? ""
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            lastPinError = trimmed.isEmpty
                ? "brew \(verbName) exited \(exit)"
                : trimmed
        case .binaryNotFound(let reason):
            lastPinError = "brew not available: \(reason)"
        }
    }

    // MARK: - Index loader / tap add+remove

    /// Refresh the in-memory index. Reads brew 6's consolidated
    /// internal index + the Steading tap-cache from disk, spawns
    /// `brew list` to derive
    /// installed/pinned sets, spawns `brew tap-info` to populate the
    /// Origin sidebar, and composes the result into `rows` + `taps`.
    /// Each call always runs against its own `outdated` argument —
    /// when two calls overlap (typical when the headless cycle
    /// settles after the window opens), the older loader finishes
    /// silently and the newer one's results land.
    ///
    /// - Parameter outdated: the upgradable subset, supplied by the
    ///   caller (typically `BrewUpdateManager.outdated`). Threading
    ///   it through here keeps the ownership contract intact: the
    ///   headless cycle remains the single source of truth for
    ///   `brew outdated`.
    func refresh(outdated: [OutdatedPackage]) {
        refreshGeneration += 1
        let myGeneration = refreshGeneration
        let priorState = state
        state = .loading
        Task { [weak self] in
            await self?.runRefresh(
                outdated: outdated,
                generation: myGeneration,
                priorState: priorState
            )
        }
    }

    /// Add a tap. On a zero-exit `brew tap`, refreshes the index so
    /// the new tap's packages enter the universe.
    func addTap(_ name: String, outdated: [OutdatedPackage]) {
        Task { [weak self, runner] in
            let result = await runner(["tap", name])
            if case .ran(let exit, _, _) = result, exit == 0 {
                self?.refresh(outdated: outdated)
            }
        }
    }

    /// Remove a tap. On a zero-exit `brew untap`, refreshes the index
    /// so removed packages leave the universe.
    func removeTap(_ name: String, outdated: [OutdatedPackage]) {
        Task { [weak self, runner] in
            let result = await runner(["untap", name])
            if case .ran(let exit, _, _) = result, exit == 0 {
                self?.refresh(outdated: outdated)
            }
        }
    }

    private func runRefresh(outdated: [OutdatedPackage],
                            generation: Int,
                            priorState: State) async {
        // 1. Disk-resident universe sources. brew 6's consolidated
        // index is ~15 MB on a typical dev mac and the JSON parse is
        // multi-second; running it on the main actor blanks the UI
        // (even a loading spinner can't animate). Detach the read +
        // parse so the @MainActor stays responsive while we wait.
        let packagesFromCache = await readPackagesIndexAsync()
        let tapPackages = await readTapIndexEntriesAsync()

        // 2. Subprocess sources.
        let installedFormulaeNames = await runListLines(["list", "--formula", "-1"])
        let installedCaskNames = await runListLines(["list", "--cask", "-1"])
        let pinnedNames = await runListLines(["list", "--pinned"])
        let taps = await fetchTapInfo()

        // 3. A newer refresh has superseded this one — drop on the
        // floor without writing back.
        guard generation == refreshGeneration else { return }

        // 4. Compose into rows.
        let installed = Set(installedFormulaeNames + installedCaskNames)
        let pinned = Set(pinnedNames)
        let outdatedTokens = Set(outdated.map(\.name))

        let allEntries = packagesFromCache + tapPackages
        let composedRows = allEntries.map { entry -> PackageRow in
            let token = entry.token
            let full = entry.fullToken
            return PackageRow(
                entry: entry,
                isInstalled: installed.contains(token) || installed.contains(full),
                isOutdated: outdatedTokens.contains(token) || outdatedTokens.contains(full),
                isPinned: pinned.contains(token) || pinned.contains(full)
            )
        }

        rows = composedRows
        self.taps = taps
        // Don't clobber an .applying state; only flip back to .idle if
        // we entered as .loading.
        if state == .loading {
            state = .idle
        } else {
            state = priorState
        }
    }

    private func readPackagesIndexAsync() async -> [BrewIndexEntry] {
        let resolver = packagesIndexPathResolver
        let reader = dataReader
        return await Task.detached(priority: .userInitiated) {
            guard let url = resolver() else { return [] }
            guard let data = try? reader(url) else { return [] }
            return (try? BrewIndexParser.parsePackagesIndex(data)) ?? []
        }.value
    }

    private func readTapIndexEntriesAsync() async -> [BrewIndexEntry] {
        let resolver = tapIndexCachePathResolver
        let reader = dataReader
        return await Task.detached(priority: .userInitiated) {
            guard let url = resolver() else { return [] }
            guard let data = try? reader(url) else { return [] }
            return (try? BrewIndexParser.parseInfoEnvelope(data)) ?? []
        }.value
    }

    private func runListLines(_ argv: [String]) async -> [String] {
        let result = await runner(argv)
        guard case .ran(let exit, let stdout, _) = result, exit == 0 else { return [] }
        guard let text = String(data: stdout, encoding: .utf8) else { return [] }
        return text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func fetchTapInfo() async -> [BrewTapInfo] {
        let result = await runner(["tap-info", "--json", "--installed"])
        guard case .ran(let exit, let stdout, _) = result, exit == 0 else { return [] }
        return (try? BrewTapInfoParser.parse(stdout)) ?? []
    }

    // MARK: - Index population

    /// Replace the in-memory universe + tap list. Called by the index
    /// loader (subsequent commit) and directly by integration tests
    /// to seed manager state without spawning brew. Resets state to
    /// `.idle` if currently `.loading`.
    func setIndex(rows: [PackageRow], taps: [BrewTapInfo]) {
        self.rows = rows
        self.taps = taps
        if case .loading = state { state = .idle }
    }

    // MARK: - Apply pipeline

    /// Kick off the Apply pipeline against the currently-marked rows.
    /// Two-phase execution (add then remove), with the post-uninstall
    /// autoremove confirmation injected between the remove sub-call
    /// and pipeline completion. The pipeline is a no-op if no marks
    /// imply a sub-call (e.g. all marked rows currently produce empty
    /// argv tails — possible only at the empty-mark boundary).
    func apply(owner: String = BrewPackageManager.packageManagerWindowID) {
        startApply(argv: Self.applyArgv(for: markedRows), owner: owner)
    }

    /// Install one or more formulae/casks by token. Convenience over
    /// `startApply` for triggers outside the package window — the
    /// Tailscale pane, future per-service installs — so they funnel
    /// through the same engine and the same shared "Applying…" modal.
    func install(_ tokens: [String], owner: String) {
        startApply(
            argv: ApplyArgv(upgrades: [], installs: tokens, removes: []),
            owner: owner
        )
    }

    /// Start a brew Apply for an explicit argv, owned by `owner`. No-op
    /// if one is already in flight or the argv is empty. This is the
    /// single entry point every user-triggered brew mutation flows
    /// through; `apply()` and `install(_:owner:)` are thin callers.
    func startApply(argv: ApplyArgv, owner: String) {
        guard applyTask == nil else { return }
        if argv.isEmpty { return }

        ownerWindowID = owner
        applyLog = ""
        applyLogBuffer = ""
        applyLogFlushScheduled = false
        recentApplyOutcome = nil
        pendingAutoremoveConfirmation = false
        state = .applying

        applyTask = Task { [weak self] in
            await self?.runApplyPipeline(argv: argv)
        }
    }

    /// Dismiss a finished Apply: clears the outcome and the owning
    /// window so the shared modal closes. No-op while still applying —
    /// the modal's Done button is gated on a terminal state.
    func dismissResult() {
        guard state != .applying else { return }
        recentApplyOutcome = nil
        ownerWindowID = nil
    }

    /// Cancel an in-flight Apply by sending the active sub-call its
    /// SIGTERM → SIGKILL sequence. The Apply task still runs to
    /// completion so the outcome lands in `recentApplyOutcome` and
    /// the state machine returns to `.idle`.
    func cancelApply() {
        inflightHandle?.cancel()
        // If we're paused on the autoremove confirmation, fail-safe to
        // No so the pipeline drains and state returns to .idle.
        if pendingAutoremoveConfirmation {
            confirmAutoremove(false)
        }
    }

    /// View entry point for the post-uninstall autoremove dialog.
    /// Yes runs `brew autoremove`; No ends the pipeline cleanly.
    func confirmAutoremove(_ accept: Bool) {
        guard pendingAutoremoveConfirmation else { return }
        pendingAutoremoveConfirmation = false
        autoremoveContinuation?.resume(returning: accept)
        autoremoveContinuation = nil
    }

    private func runApplyPipeline(argv: ApplyArgv) async {
        // Add phase 1: upgrades.
        if !argv.upgrades.isEmpty {
            let outcome = await runSubCall(["upgrade"] + argv.upgrades)
            guard case .success = outcome else {
                finishApply(outcome: outcome)
                return
            }
        }
        // Add phase 2: installs.
        if !argv.installs.isEmpty {
            let outcome = await runSubCall(["install"] + argv.installs)
            guard case .success = outcome else {
                finishApply(outcome: outcome)
                return
            }
        }
        // Remove phase + autoremove confirmation.
        let removeRan = !argv.removes.isEmpty
        if removeRan {
            let outcome = await runSubCall(["uninstall"] + argv.removes)
            guard case .success = outcome else {
                finishApply(outcome: outcome)
                return
            }
            pendingAutoremoveConfirmation = true
            let accept = await waitForAutoremoveDecision()
            if accept {
                let autoOutcome = await runSubCall(["autoremove"])
                guard case .success = autoOutcome else {
                    finishApply(outcome: autoOutcome)
                    return
                }
            }
        }
        finishApply(outcome: .success)
    }

    private func runSubCall(_ argv: [String]) async -> ApplyOutcome {
        let handle = subCallRunner(argv)
        inflightHandle = handle
        defer { inflightHandle = nil }

        var outcome: ApplyOutcome = .cancelled
        for await event in handle.events {
            switch event {
            case .output(let piece):
                appendApplyOutput(piece)
            case .finished(let o):
                outcome = o
            }
        }
        return outcome
    }

    private func waitForAutoremoveDecision() async -> Bool {
        await withCheckedContinuation { continuation in
            self.autoremoveContinuation = continuation
        }
    }

    private func finishApply(outcome: ApplyOutcome) {
        applyTask = nil
        inflightHandle = nil
        flushApplyLog()
        recentApplyOutcome = outcome
        state = .idle
    }

    /// Buffer one piece of brew output and ensure a single coalesced
    /// flush is pending. Appending to the non-observed buffer doesn't
    /// touch the view; the flush publishes a bounded tail at ~10 Hz.
    private func appendApplyOutput(_ piece: String) {
        applyLogBuffer += piece
        guard !applyLogFlushScheduled else { return }
        applyLogFlushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            self?.flushApplyLog()
        }
    }

    /// Publish the bounded tail of the buffer into the observed
    /// `applyLog`. Called on the ~10 Hz timer and once eagerly from
    /// `finishApply` so the final bytes land the moment Apply settles.
    private func flushApplyLog() {
        applyLogFlushScheduled = false
        applyLogBuffer = Self.displayTail(applyLogBuffer)
        applyLog = applyLogBuffer
    }

    // MARK: - Default runners

    /// Build the production sub-call runner. The resolvers are the
    /// brew-spawn boundary (kept on `BrewUpdateManager` because regen
    /// also needs them); the returned closure spawns brew via
    /// `StreamingProcessRunner` with `SUDO_ASKPASS` set when a
    /// helper is available, streams stdout/stderr as they arrive,
    /// and emits one terminal `.finished` event.
    ///
    /// Exposed as a factory rather than a `let` so the askpass-env
    /// integration tests can pass a fake-brew + fake-helper pair
    /// without rebuilding the streaming wiring from scratch.
    nonisolated static func defaultSubCallRunner(
        brewPathResolver: @escaping BrewUpdateManager.BrewPathResolver = BrewUpdateManager.defaultBrewPathResolver,
        askpassHelperResolver: @escaping BrewUpdateManager.AskpassHelperResolver = BrewUpdateManager.defaultAskpassHelperResolver
    ) -> SubCallRunner {
        return { argv in
            guard let brewPath = brewPathResolver() else {
                return failedHandle(reason: "no brew on disk")
            }
            var env = ProcessInfo.processInfo.environment
            if let helper = askpassHelperResolver() {
                env["SUDO_ASKPASS"] = helper
            } else {
                env.removeValue(forKey: "SUDO_ASKPASS")
            }
            let handle = StreamingProcessRunner.run(
                executable: brewPath,
                arguments: argv,
                environment: env
            )
            let stream = AsyncStream<SubCallEvent> { continuation in
                Task {
                    for await event in handle.events {
                        switch event {
                        case .output(_, let data):
                            let piece = String(data: data, encoding: .utf8) ?? ""
                            continuation.yield(.output(piece))
                        case .exited(let code):
                            let outcome: ApplyOutcome = (code == 0)
                                ? .success
                                : .failed(exitCode: code)
                            continuation.yield(.finished(outcome))
                        case .cancelled:
                            continuation.yield(.finished(.cancelled))
                        case .failed(let reason):
                            continuation.yield(.finished(.spawnFailed(reason: reason)))
                        }
                    }
                    continuation.finish()
                }
            }
            return SubCallHandle(events: stream, cancel: handle.cancel)
        }
    }

    /// Build a SubCallHandle that emits one immediate
    /// `.finished(.spawnFailed)` and finishes — used when brew can't
    /// be located before a sub-call is spawned.
    private nonisolated static func failedHandle(reason: String) -> SubCallHandle {
        let stream = AsyncStream<SubCallEvent> { continuation in
            continuation.yield(.finished(.spawnFailed(reason: reason)))
            continuation.finish()
        }
        return SubCallHandle(events: stream, cancel: {})
    }

    /// Default packages-index path resolver: brew 6's consolidated
    /// internal index, which is platform-specific
    /// (`packages.arm64_tahoe.jws.json` and so on). Rather than
    /// reconstruct the bottle tag from the running OS — which would
    /// need a macOS-codename map maintained per release — we glob the
    /// `internal/` directory for the single `packages.*.jws.json` file
    /// brew generates for this host. Returns `nil` if the directory or
    /// file is missing; the loader treats that as "no entries", not a
    /// hard error.
    nonisolated static let defaultPackagesIndexPathResolver: PackagesIndexPathResolver = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(
            "Library/Caches/Homebrew/api/internal/", isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return contents.first { url in
            let name = url.lastPathComponent
            return name.hasPrefix("packages.") && name.hasSuffix(".jws.json")
        }
    }

    /// Default file reader: `Data(contentsOf:)` with no special
    /// options. Tests inject a closure returning canned bytes.
    nonisolated static let defaultDataReader: DataReader = { url in
        try Data(contentsOf: url)
    }

    // MARK: - Marking

    func mark(_ id: String, _ on: Bool) {
        if on { marked.insert(id) } else { marked.remove(id) }
    }

    /// Mark every upgradable row. Idempotent.
    func markAllUpgrades() {
        for row in rows where row.isOutdated {
            marked.insert(row.id)
        }
    }

    func unmarkAll() {
        marked.removeAll()
    }

    // MARK: - Filtered view

    /// The current filtered slice the list pane shows, derived from
    /// `sidebarMode` + the active filter values.
    var filteredRows: [PackageRow] {
        switch sidebarMode {
        case .status:
            return rows.filter { Self.matches($0, statusFilter: statusFilter) }
        case .origin:
            guard let tap = originTap else { return [] }
            return rows.filter { Self.matches($0, originTap: tap) }
        case .searchResults:
            let lowered = searchText.lowercased()
            return rows.filter { Self.matches($0, searchLowered: lowered) }
        }
    }

    /// The marked rows, in the same order they appear in the unfiltered
    /// universe. Apply uses this — partial-failure ordering needs to
    /// be predictable and not depend on filter state.
    var markedRows: [PackageRow] {
        rows.filter { marked.contains($0.id) }
    }

    /// Count used by the toolbar's `markAllEnabled` decision: every
    /// row whose state implies an upgrade verb when checked.
    var upgradableCount: Int {
        rows.reduce(into: 0) { $0 += $1.isOutdated ? 1 : 0 }
    }
}

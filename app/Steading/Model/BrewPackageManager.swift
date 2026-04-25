import Foundation
import Observation

/// UI-facing brew model for the Brew Package Manager window. Owns the
/// unified package index loaded from brew's JWS cache + the
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
        let lowered = needle.lowercased()
        if lowered.isEmpty { return false }
        if row.entry.token.lowercased().contains(lowered) { return true }
        if row.entry.fullToken.lowercased().contains(lowered) { return true }
        if let desc = row.entry.desc?.lowercased(), desc.contains(lowered) { return true }
        return false
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
    /// arrival order. Reset at the start of each Apply.
    private(set) var applyLog: String = ""

    /// Outcome of the most recent Apply. `nil` until the first Apply
    /// completes; cleared at the start of each fresh Apply.
    private(set) var recentApplyOutcome: ApplyOutcome?

    /// True while the Apply pipeline is paused on the post-uninstall
    /// autoremove confirmation. The view shows the dialog while this
    /// is true; pressing Yes/No calls `confirmAutoremove(_:)`.
    private(set) var pendingAutoremoveConfirmation: Bool = false

    /// Installed taps in display order, refreshed alongside the index.
    private(set) var taps: [BrewTapInfo] = []

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

    // MARK: - Lifecycle

    private let subCallRunner: SubCallRunner
    private var applyTask: Task<Void, Never>?
    private var inflightHandle: SubCallHandle?
    private var autoremoveContinuation: CheckedContinuation<Bool, Never>?

    init(subCallRunner: @escaping SubCallRunner = BrewPackageManager.defaultSubCallRunner) {
        self.subCallRunner = subCallRunner
        // The skeleton starts in `.idle` rather than `.loading` until
        // an index loader lands; the loader sub-commit flips this.
        self.state = .idle
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
    func apply() {
        guard applyTask == nil else { return }
        let rows = markedRows
        let argv = Self.applyArgv(for: rows)
        if argv.isEmpty { return }

        applyLog = ""
        recentApplyOutcome = nil
        pendingAutoremoveConfirmation = false
        state = .applying

        applyTask = Task { [weak self] in
            await self?.runApplyPipeline(argv: argv)
        }
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
                applyLog += piece
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
        recentApplyOutcome = outcome
        state = .idle
    }

    // MARK: - Default runners

    /// Production sub-call runner: spawns brew via
    /// `StreamingProcessRunner` with the same brew-path + askpass
    /// resolution the prior `BrewUpdateManager.apply` used. Streams
    /// stdout/stderr as they arrive and emits one terminal `.finished`
    /// event carrying the resolved [ApplyOutcome].
    nonisolated static let defaultSubCallRunner: SubCallRunner = { argv in
        let brewPath = BrewDetector.standardSearchPaths.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        guard let brewPath else {
            return failedHandle(reason: "no brew on disk")
        }

        var env = ProcessInfo.processInfo.environment
        if let exec = Bundle.main.executableURL {
            let askpass = exec.deletingLastPathComponent()
                .appendingPathComponent("steading-askpass").path
            if FileManager.default.isExecutableFile(atPath: askpass) {
                env["SUDO_ASKPASS"] = askpass
            }
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
            return rows.filter { Self.matches($0, search: searchText) }
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

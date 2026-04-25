import Foundation
import Observation
import UserNotifications

/// Owns the brew-updater check pipeline. One instance is created at
/// app launch and handed to views via the environment. The manager is
/// main-actor-confined and exposes `@Observable` state the UI binds to
/// directly.
///
/// Scheduling rules, the retry back-off curve, and the concurrency
/// contract are spelled out in the plan's Phase 2 section. The pure
/// helpers (`shouldFireOnStartup`, `nextRetryDelay`) are `static` so
/// tests exercise them directly without standing up a manager.
@Observable
@MainActor
final class BrewUpdateManager {

    enum State: Equatable {
        case idle(count: Int)
        case checking
        case failed(message: String)
        case applying
    }

    /// Outcome of the most recent Apply, kept on the manager so the
    /// window's progress area can display a success/failure/cancel
    /// indicator briefly after the upgrade finishes.
    enum ApplyOutcome: Equatable {
        case success
        case failed(exitCode: Int32)
        case cancelled
        case spawnFailed(reason: String)
    }

    /// Dependency boundary for locating the brew binary. Default
    /// walks `BrewDetector.standardSearchPaths`; tests inject a path
    /// to a fake brew so real brew doesn't run.
    typealias BrewPathResolver = @Sendable () -> String?

    /// Dependency boundary for locating the bundled `steading-askpass`
    /// helper. Default returns the path next to the main app binary;
    /// tests can inject any path (or `nil` to skip the `SUDO_ASKPASS`
    /// env entirely).
    typealias AskpassHelperResolver = @Sendable () -> String?

    /// Dependency boundary for locating the on-disk Steading-owned
    /// tap-cache file. Default lives under `~/Library/Caches/com.xalior.Steading/`;
    /// tests inject a sandbox path. Returns `nil` to skip the regen
    /// write entirely (used by tests that only want to assert the
    /// regen pipeline doesn't push state to `.failed`).
    typealias TapIndexCachePathResolver = @Sendable () -> URL?

    /// Dependency boundary for the tap-cache write step. Default uses
    /// `Data.write(to:options: .atomic)` — same-directory tmp file +
    /// atomic rename, so a partial write cannot replace the prior
    /// cache on disk. Tests inject an in-memory accumulator (whose
    /// store-into-actor side effect needs the async-throwing shape;
    /// a synchronous default closure satisfies the async signature).
    typealias TapIndexWriter = @Sendable (URL, Data) async throws -> Void

    /// Enablement decisions for the Brew Package Manager window's
    /// controls. Pure — derived from state and counts.
    struct Buttons: Equatable, Sendable {
        let applyEnabled: Bool
        let checkNowEnabled: Bool
        let markAllEnabled: Bool
        let perRowEnabled: Bool
        let cancelEnabled: Bool
    }

    enum StartupDecision: Equatable {
        case fireNow
        case waitThenFire(delay: TimeInterval)
    }

    /// The shape the manager expects back from the subprocess surface.
    /// `.binaryNotFound` covers ENOENT / permission-denied / missing
    /// path — settles fail-fast with no retry. `.ran` is a successful
    /// process invocation whose exit code drives the retry decision.
    enum RunResult: Sendable, Equatable {
        case ran(exitCode: Int32, stdout: Data, stderr: Data)
        case binaryNotFound(reason: String)
    }

    typealias Runner = @Sendable (_ arguments: [String]) async -> RunResult
    typealias Sleeper = @Sendable (_ duration: Duration) async throws -> Void

    /// Dependency boundary for the system-notification surface. The
    /// production implementation (`defaultNotifier`) hits
    /// `UNUserNotificationCenter.current()`; tests supply a no-op or
    /// accumulator so the real settlement code path runs against a
    /// controlled substitute.
    struct BannerNotifier: Sendable {
        var post: @Sendable (_ count: Int) -> Void
        var removeDelivered: @Sendable () -> Void
    }

    /// Max total attempts per check chain: initial + 4 retries = 5.
    static let maxAttempts = 5

    private(set) var state: State = .idle(count: 0)
    private(set) var outdated: [OutdatedPackage] = []

    /// Streaming output from the in-flight Apply, UTF-8 decoded in
    /// arrival order. Empty before the first Apply and reset at the
    /// start of each Apply.
    private(set) var applyLog: String = ""

    /// Outcome of the most recent Apply run. `nil` until the first
    /// Apply completes; cleared when a fresh Apply begins or when a
    /// fresh check begins.
    private(set) var recentApplyOutcome: ApplyOutcome?

    private let preferences: PreferencesStore
    private let runner: Runner
    private let sleep: Sleeper
    private let clock: @Sendable () -> Date
    private let notifier: BannerNotifier
    private let brewPathResolver: BrewPathResolver
    private let askpassHelperResolver: AskpassHelperResolver
    private let tapIndexCachePathResolver: TapIndexCachePathResolver
    private let tapIndexWriter: TapIndexWriter
    /// Count from the most recent successful settlement. Dock badge
    /// and menu bar label derive from this so they don't flicker off
    /// while a check is in flight.
    private(set) var lastSettledCount: Int = 0
    private var lastNotifyBannerPref: Bool

    private var checkTask: Task<Void, Never>?
    private var scheduledTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?
    private var applyHandle: StreamingProcessRunner.Handle?

    init(preferences: PreferencesStore,
         runner: @escaping Runner = BrewUpdateManager.defaultRunner,
         sleep: @escaping Sleeper = { try await Task.sleep(for: $0) },
         clock: @escaping @Sendable () -> Date = { Date() },
         notifier: BannerNotifier = BrewUpdateManager.defaultNotifier,
         brewPathResolver: @escaping BrewPathResolver = BrewUpdateManager.defaultBrewPathResolver,
         askpassHelperResolver: @escaping AskpassHelperResolver = BrewUpdateManager.defaultAskpassHelperResolver,
         tapIndexCachePathResolver: @escaping TapIndexCachePathResolver = BrewUpdateManager.defaultTapIndexCachePathResolver,
         tapIndexWriter: @escaping TapIndexWriter = BrewUpdateManager.defaultTapIndexWriter) {
        self.preferences               = preferences
        self.runner                    = runner
        self.sleep                     = sleep
        self.clock                     = clock
        self.notifier                  = notifier
        self.brewPathResolver          = brewPathResolver
        self.askpassHelperResolver     = askpassHelperResolver
        self.tapIndexCachePathResolver = tapIndexCachePathResolver
        self.tapIndexWriter            = tapIndexWriter
        self.lastNotifyBannerPref      = preferences.notifySystemBanner
    }

    // MARK: - Lifecycle

    /// Kick off the scheduler based on the current preferences and the
    /// persisted `lastCheckAt`. Idempotent: calling twice is safe —
    /// the second call replaces the pending scheduled task.
    func start() {
        scheduledTask?.cancel()
        let decision = Self.shouldFireOnStartup(
            lastCheckAt: preferences.lastCheckAt,
            interval: TimeInterval(preferences.checkIntervalHours) * 3600,
            checkOnLaunch: preferences.checkOnLaunch,
            now: clock()
        )
        switch decision {
        case .fireNow:
            check()
        case .waitThenFire(let delay):
            scheduleDelayedCheck(after: .seconds(delay))
        }
    }

    /// Cancel any pending scheduled tick and any in-flight check chain.
    func stop() {
        scheduledTask?.cancel()
        scheduledTask = nil
        checkTask?.cancel()
        checkTask = nil
        applyHandle?.cancel()
        applyHandle = nil
        applyTask?.cancel()
        applyTask = nil
    }

    // MARK: - Check pipeline

    /// Request a check. Silently no-ops if a chain is already in
    /// flight — the concurrency contract.
    func check() {
        guard checkTask == nil else { return }
        scheduledTask?.cancel()
        scheduledTask = nil
        state = .checking
        checkTask = Task { [weak self] in
            await self?.runChain()
            self?.finishChain()
        }
    }

    private func finishChain() {
        checkTask = nil
        let interval = TimeInterval(preferences.checkIntervalHours) * 3600
        scheduleDelayedCheck(after: .seconds(interval))
    }

    private func scheduleDelayedCheck(after duration: Duration) {
        scheduledTask?.cancel()
        scheduledTask = Task { [weak self, sleep] in
            do {
                try await sleep(duration)
            } catch {
                return
            }
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.check()
            }
        }
    }

    private func runChain() async {
        var attempts = 0
        while true {
            attempts += 1
            let outcome = await runOneAttempt()
            switch outcome {
            case .success(let packages):
                settle(success: packages)
                await regenerateTapIndex()
                return
            case .failFast(let message):
                settle(failed: message)
                return
            case .ranNonZero(let message):
                if attempts >= Self.maxAttempts {
                    settle(failed: message)
                    return
                }
                guard let delay = Self.nextRetryDelay(attempt: attempts) else {
                    settle(failed: message)
                    return
                }
                do {
                    try await sleep(delay)
                } catch {
                    return
                }
            }
        }
    }

    private enum AttemptOutcome {
        case success([OutdatedPackage])
        case failFast(String)
        case ranNonZero(String)
    }

    private func runOneAttempt() async -> AttemptOutcome {
        switch await runner(["update"]) {
        case .binaryNotFound(let reason):
            return .failFast("brew not available: \(reason)")
        case .ran(let code, _, let stderr) where code != 0:
            return .ranNonZero(terseStderr(stderr, fallback: "brew update exited \(code)"))
        case .ran:
            break
        }

        switch await runner(["outdated", "--json=v2"]) {
        case .binaryNotFound(let reason):
            return .failFast("brew not available: \(reason)")
        case .ran(let code, _, let stderr) where code != 0:
            return .ranNonZero(terseStderr(stderr, fallback: "brew outdated exited \(code)"))
        case .ran(_, let stdout, _):
            do {
                let packages = try BrewOutdatedParser.parse(stdout)
                return .success(packages)
            } catch {
                return .failFast("unexpected brew outdated output")
            }
        }
    }

    private func settle(success packages: [OutdatedPackage]) {
        let previousCount = lastSettledCount
        outdated = packages
        state = .idle(count: packages.count)
        preferences.lastCheckAt = clock()
        lastSettledCount = packages.count
        applyBannerAction(Self.bannerActionOnSettle(
            previousCount: previousCount,
            newCount: packages.count,
            enabled: preferences.notifySystemBanner
        ))
    }

    private func settle(failed message: String) {
        outdated = []
        state = .failed(message: message)
        preferences.lastCheckAt = clock()
    }

    /// Act on a preference toggle. Called from the app when the user
    /// flips a notification-style checkbox — pure decision + imperative
    /// side effects are split between this entry point and the pure
    /// `bannerActionOnPrefChange` / `dockBadgeLabel` / `menuBarShowsCount`
    /// helpers.
    func preferencesChanged() {
        let action = Self.bannerActionOnPrefChange(
            wasEnabled: lastNotifyBannerPref,
            isEnabled: preferences.notifySystemBanner
        )
        lastNotifyBannerPref = preferences.notifySystemBanner
        applyBannerAction(action)
    }

    private func applyBannerAction(_ action: BannerAction) {
        switch action {
        case .post(let count):
            notifier.post(count)
        case .removeDelivered:
            notifier.removeDelivered()
        case .noop:
            break
        }
    }

    // MARK: - Tap-cache regen
    //
    // Soft post-settle step that keeps `~/Library/Caches/com.xalior.Steading/tap-index.json`
    // in step with brew's own JWS cache. Spawns `brew tap-info`, drops
    // `homebrew/core` / `homebrew/cask`, and runs `brew info --json=v2`
    // against the union of remaining `formula_names` + `cask_tokens`.
    //
    // Failure-isolated by contract: nothing this method does can push
    // the brew-updater state machine into `.failed` or trigger retry
    // back-off. Every failure path returns silently. The atomic-write
    // discipline (`Data.write(.atomic)` in the default writer) means a
    // partial write cannot replace the prior cache on disk.
    private func regenerateTapIndex() async {
        let tapInfoResult = await runner(["tap-info", "--json", "--installed"])
        guard case let .ran(tapExit, tapStdout, _) = tapInfoResult, tapExit == 0 else {
            return
        }

        let taps: [BrewTapInfo]
        do {
            taps = try BrewTapInfoParser.parse(tapStdout)
        } catch {
            return
        }

        let userTaps = BrewTapInfoParser.userTaps(taps)
        let packageNames = BrewTapInfoParser.packageNames(in: userTaps)

        let document: Data
        if packageNames.isEmpty {
            document = #"{"formulae":[],"casks":[]}"#.data(using: .utf8) ?? Data()
        } else {
            let infoResult = await runner(["info", "--json=v2"] + packageNames)
            guard case let .ran(infoExit, infoStdout, _) = infoResult, infoExit == 0 else {
                return
            }
            do {
                _ = try BrewIndexParser.parseInfoEnvelope(infoStdout)
            } catch {
                return
            }
            document = infoStdout
        }

        guard let path = tapIndexCachePathResolver() else { return }
        try? await tapIndexWriter(path, document)
    }

    private func terseStderr(_ stderr: Data, fallback: String) -> String {
        let raw = String(data: stderr, encoding: .utf8) ?? ""
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? fallback : trimmed
    }

    // MARK: - Apply pipeline

    /// Kick off `brew upgrade <packages…>`, streaming output into
    /// `applyLog`. Stage-2 askpass path: no password collection up
    /// front — brew is spawned immediately with `SUDO_ASKPASS`
    /// pointing at the bundled `steading-askpass` helper. When sudo
    /// needs a password it invokes the helper, which IPCs back into
    /// the GUI to surface the password modal on demand.
    func apply(_ packages: [OutdatedPackage]) {
        guard applyTask == nil, checkTask == nil else { return }
        scheduledTask?.cancel()
        scheduledTask = nil
        applyLog = ""
        recentApplyOutcome = nil
        state = .applying

        applyTask = Task { [weak self] in
            guard let self else { return }
            await self.runBrewUpgrade(packages: packages)
        }
    }

    private func runBrewUpgrade(packages: [OutdatedPackage]) async {
        let argv = Self.brewUpgradeArgv(for: packages)
        guard let brewPath = brewPathResolver() else {
            finishApply(outcome: .spawnFailed(reason: "no brew on disk"))
            return
        }

        var env = ProcessInfo.processInfo.environment
        if let helper = askpassHelperResolver() {
            env["SUDO_ASKPASS"] = helper
        }

        let handle = StreamingProcessRunner.run(
            executable: brewPath,
            arguments: argv,
            environment: env
        )
        applyHandle = handle

        var outcome: ApplyOutcome = .cancelled
        for await event in handle.events {
            switch event {
            case .output(_, let data):
                let piece = String(data: data, encoding: .utf8) ?? ""
                self.appendLog(piece)
            case .exited(let code):
                outcome = (code == 0) ? .success : .failed(exitCode: code)
            case .cancelled:
                outcome = .cancelled
            case .failed(let reason):
                outcome = .spawnFailed(reason: reason)
            }
        }
        finishApply(outcome: outcome)
    }

    /// Cancel an in-flight Apply by sending SIGTERM → SIGKILL to brew.
    /// The apply task still runs to completion so the outcome lands
    /// in `recentApplyOutcome` and a post-cancel re-check fires.
    func cancelApply() {
        applyHandle?.cancel()
    }

    private func appendLog(_ piece: String) {
        applyLog += piece
    }

    private func finishApply(outcome: ApplyOutcome) {
        applyTask = nil
        applyHandle = nil
        recentApplyOutcome = outcome
        check()
    }

    // MARK: - Pure scheduler / back-off helpers

    nonisolated static func shouldFireOnStartup(lastCheckAt: Date?,
                                                interval: TimeInterval,
                                                checkOnLaunch: Bool,
                                                now: Date) -> StartupDecision {
        if checkOnLaunch { return .fireNow }
        guard let last = lastCheckAt else { return .fireNow }
        let elapsed = now.timeIntervalSince(last)
        if elapsed >= interval { return .fireNow }
        return .waitThenFire(delay: interval - elapsed)
    }

    nonisolated static func nextRetryDelay(attempt: Int) -> Duration? {
        switch attempt {
        case 1: return .seconds(60)
        case 2: return .seconds(120)
        case 3: return .seconds(240)
        case 4: return .seconds(480)
        case 5: return .seconds(900)
        default: return nil
        }
    }

    /// Build the argv for a `brew upgrade <name1> <name2> …` call.
    /// Names are passed through verbatim — `@` and other shell-special
    /// characters are fine because Process does not go through a shell.
    nonisolated static func brewUpgradeArgv(for packages: [OutdatedPackage]) -> [String] {
        ["upgrade"] + packages.map(\.name)
    }


    // MARK: - Notification surface (pure)

    enum BannerAction: Equatable, Sendable {
        case post(count: Int)
        case removeDelivered
        case noop
    }

    /// Fixed identifier so macOS replaces the Notification Center
    /// entry on each post rather than stacking duplicates.
    nonisolated static let notificationIdentifier = "com.xalior.Steading.brew-updates"

    nonisolated static func dockBadgeLabel(count: Int, enabled: Bool) -> String? {
        guard enabled, count > 0 else { return nil }
        return "\(count)"
    }

    nonisolated static func menuBarShowsCount(count: Int, enabled: Bool) -> Bool {
        enabled && count > 0
    }

    nonisolated static func bannerActionOnSettle(previousCount: Int,
                                                 newCount: Int,
                                                 enabled: Bool) -> BannerAction {
        guard enabled else { return .noop }
        if newCount > 0 { return .post(count: newCount) }
        return previousCount > 0 ? .removeDelivered : .noop
    }

    nonisolated static func bannerActionOnPrefChange(wasEnabled: Bool,
                                                     isEnabled: Bool) -> BannerAction {
        if wasEnabled && !isEnabled { return .removeDelivered }
        return .noop
    }

    /// Map manager state + selection counts to the Brew Package
    /// Manager window's button enablement. Pure.
    nonisolated static func buttons(state: State,
                                    markedCount: Int,
                                    outdatedCount: Int) -> Buttons {
        let isChecking = state == .checking
        let isApplying = state == .applying

        return Buttons(
            applyEnabled:    !isChecking && !isApplying && markedCount > 0,
            checkNowEnabled: !isChecking && !isApplying,
            markAllEnabled:  !isChecking && !isApplying && outdatedCount > 0,
            perRowEnabled:   !isApplying,
            cancelEnabled:   isApplying
        )
    }

    // MARK: - Default notifier

    nonisolated static let defaultNotifier: BannerNotifier = BannerNotifier(
        post: { count in
            let content = UNMutableNotificationContent()
            content.title = "Brew updates available"
            content.body  = count == 1
                ? "1 pending update"
                : "\(count) pending updates"
            let request = UNNotificationRequest(
                identifier: BrewUpdateManager.notificationIdentifier,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        },
        removeDelivered: {
            UNUserNotificationCenter.current().removeDeliveredNotifications(
                withIdentifiers: [BrewUpdateManager.notificationIdentifier]
            )
        }
    )

    // MARK: - Default resolvers

    nonisolated static let defaultBrewPathResolver: BrewPathResolver = {
        BrewDetector.standardSearchPaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        })
    }

    /// Default askpass helper path: the `steading-askpass` binary
    /// bundled next to the main app executable. Returns `nil` if it
    /// isn't present (unsigned dev builds, tests) so callers can
    /// decide whether to skip the `SUDO_ASKPASS` env entirely.
    nonisolated static let defaultAskpassHelperResolver: AskpassHelperResolver = {
        guard let exec = Bundle.main.executableURL else { return nil }
        let candidate = exec.deletingLastPathComponent()
            .appendingPathComponent("steading-askpass").path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    /// Default tap-cache path: `~/Library/Caches/com.xalior.Steading/tap-index.json`.
    /// Creates the containing directory on demand; returns `nil` if
    /// neither the user caches dir nor the Steading subdir is
    /// accessible (regen then bails silently).
    nonisolated static let defaultTapIndexCachePathResolver: TapIndexCachePathResolver = {
        let fm = FileManager.default
        guard let cachesURL = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = cachesURL.appendingPathComponent("com.xalior.Steading", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return dir.appendingPathComponent("tap-index.json")
    }

    /// Default tap-cache writer: `Data.write(.atomic)` does temp-file
    /// in same dir + fsync + rename, so a partial write cannot replace
    /// the prior cache file.
    nonisolated static let defaultTapIndexWriter: TapIndexWriter = { url, data in
        try data.write(to: url, options: [.atomic])
    }

    // MARK: - Default runner

    /// Locate brew at one of the standard paths and spawn it. Returns
    /// `.binaryNotFound` when no standard path is executable or when
    /// Process.run() throws. Otherwise returns `.ran(...)` with the
    /// real exit code and captured output.
    nonisolated static let defaultRunner: Runner = { arguments in
        guard let brewPath = BrewDetector.standardSearchPaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            let joined = BrewDetector.standardSearchPaths.joined(separator: ", ")
            return .binaryNotFound(reason: "no brew at \(joined)")
        }
        return await Task.detached { () -> RunResult in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: brewPath)
            process.arguments = arguments
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            do {
                try process.run()
            } catch {
                return .binaryNotFound(reason: "spawn failed: \(error.localizedDescription)")
            }
            process.waitUntilExit()
            let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
            let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            return .ran(exitCode: process.terminationStatus, stdout: outData, stderr: errData)
        }.value
    }
}

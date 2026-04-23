import Foundation
import Observation

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

    private var checkTask: Task<Void, Never>?
    private var scheduledTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?
    private var applyHandle: StreamingProcessRunner.Handle?

    init(preferences: PreferencesStore,
         runner: @escaping Runner = BrewUpdateManager.defaultRunner,
         sleep: @escaping Sleeper = { try await Task.sleep(for: $0) },
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.preferences = preferences
        self.runner      = runner
        self.sleep       = sleep
        self.clock       = clock
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
        outdated = packages
        state = .idle(count: packages.count)
        preferences.lastCheckAt = clock()
    }

    private func settle(failed message: String) {
        outdated = []
        state = .failed(message: message)
        preferences.lastCheckAt = clock()
    }

    private func terseStderr(_ stderr: Data, fallback: String) -> String {
        let raw = String(data: stderr, encoding: .utf8) ?? ""
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? fallback : trimmed
    }

    // MARK: - Apply pipeline

    /// Kick off `brew upgrade <packages…>`, streaming output into
    /// `applyLog`. Silently no-ops if the manager is already applying
    /// or currently checking. On completion (success, failure, or
    /// cancel) a fresh check is scheduled so the list reflects the
    /// post-upgrade reality.
    func apply(_ packages: [OutdatedPackage]) {
        guard applyTask == nil, checkTask == nil else { return }
        scheduledTask?.cancel()
        scheduledTask = nil
        applyLog = ""
        recentApplyOutcome = nil
        state = .applying

        let argv = Self.brewUpgradeArgv(for: packages)
        guard let brewPath = BrewDetector.standardSearchPaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            recentApplyOutcome = .spawnFailed(reason: "no brew on disk")
            state = .failed(message: "brew not available")
            return
        }
        let handle = StreamingProcessRunner.run(executable: brewPath, arguments: argv)
        applyHandle = handle

        applyTask = Task { [weak self] in
            var outcome: ApplyOutcome = .cancelled
            for await event in handle.events {
                guard let self else { return }
                switch event {
                case .output(_, let data):
                    let piece = String(data: data, encoding: .utf8) ?? ""
                    await self.appendLog(piece)
                case .exited(let code):
                    outcome = (code == 0) ? .success : .failed(exitCode: code)
                case .cancelled:
                    outcome = .cancelled
                case .failed(let reason):
                    outcome = .spawnFailed(reason: reason)
                }
            }
            self?.finishApply(outcome: outcome)
        }
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

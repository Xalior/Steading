import Testing
import Foundation
@testable import Steading

/// Integration tests that exercise the real `BrewUpdateManager` retry
/// loop, state machine, and concurrency contract. The subprocess
/// surface is substituted via the `runner` boundary; the sleep
/// boundary fast-forwards retry delays while leaving scheduled
/// interval ticks pending so the test has a chance to stop the
/// manager before it self-reschedules.
@Suite("BrewUpdateManager")
@MainActor
struct BrewUpdateManagerTests {

    nonisolated static let emptyOutdatedJSON = #"{"formulae": [], "casks": []}"#
        .data(using: .utf8)!

    private func scratchPreferences() -> (PreferencesStore, String) {
        let suite = "com.xalior.Steading.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (PreferencesStore(defaults: defaults), suite)
    }

    private func teardown(_ suite: String) {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    /// Sleeper that fast-forwards retry delays (≤ 15 min) and blocks
    /// until cancellation for scheduled interval ticks (hours). The
    /// test calls `manager.stop()` to release the blocked task.
    private let fastSleep: BrewUpdateManager.Sleeper = { duration in
        if duration <= .seconds(900) { return }
        try await Task.sleep(for: .seconds(86_400 * 365))
    }

    private func waitForSettle(_ manager: BrewUpdateManager,
                               timeoutSeconds: Double = 2.0) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if case .checking = manager.state {
                try? await Task.sleep(for: .milliseconds(5))
                continue
            }
            return
        }
    }

    // MARK: - Concurrency contract

    @Test("second check() while a chain is in flight silently no-ops")
    func concurrency_second_check_is_noop() async {
        let (prefs, suite) = scratchPreferences()
        defer { teardown(suite) }

        let calls = CallCounter()

        let runner: BrewUpdateManager.Runner = { args in
            await calls.record(args)
            // Give the test a window to issue a second check() call.
            try? await Task.sleep(for: .milliseconds(25))
            let stdout = args == ["outdated", "--json=v2"]
                ? Self.emptyOutdatedJSON
                : Data()
            return .ran(exitCode: 0, stdout: stdout, stderr: Data())
        }

        let manager = BrewUpdateManager(
            preferences: prefs,
            runner: runner,
            sleep: fastSleep,
            clock: { Date() }
        )

        manager.check()
        #expect(manager.state == .checking)
        manager.check()
        manager.check()
        #expect(manager.state == .checking)

        await waitForSettle(manager)
        manager.stop()

        let recorded = await calls.recorded
        // First chain: "update" + "outdated", then the soft post-settle
        // tap-info probe (the regen step silently bails on the empty
        // stdout this runner returns, so no follow-up "info" call).
        // The extra check() calls MUST NOT have spawned a second chain.
        #expect(recorded.count == 3)
        #expect(recorded[0] == ["update"])
        #expect(recorded[1] == ["outdated", "--json=v2"])
        #expect(recorded[2] == ["tap-info", "--json", "--installed"])
        #expect(manager.state == .idle(count: 0))
    }

    // MARK: - Retry settlement

    @Test("retry settlement: three non-zero update failures then zero → success in four attempts")
    func retry_settles_success_after_failures() async {
        let (prefs, suite) = scratchPreferences()
        defer { teardown(suite) }

        let coordinator = UpdateExitSequence(exitCodes: [1, 1, 1, 0])
        let runner: BrewUpdateManager.Runner = { args in
            if args == ["update"] {
                let code = await coordinator.nextUpdateExit()
                return .ran(exitCode: code, stdout: Data(), stderr: Data())
            }
            if args == ["outdated", "--json=v2"] {
                await coordinator.recordOutdated()
                return .ran(exitCode: 0, stdout: Self.emptyOutdatedJSON, stderr: Data())
            }
            // Post-settle tap-regen probes (tap-info / info) — return
            // success with empty data so the regen step parses-and-bails
            // without polluting the chain-call counters.
            return .ran(exitCode: 0, stdout: Data(), stderr: Data())
        }

        let manager = BrewUpdateManager(
            preferences: prefs, runner: runner,
            sleep: fastSleep, clock: { Date() }
        )
        manager.check()
        await waitForSettle(manager, timeoutSeconds: 3)
        manager.stop()

        #expect(await coordinator.updateCalls == 4)
        #expect(await coordinator.outdatedCalls == 1)
        if case .idle(let count) = manager.state {
            #expect(count == 0)
        } else {
            Issue.record("expected .idle after settlement, got \(manager.state)")
        }
    }

    @Test("retry settlement: five non-zero update failures → surrender in five attempts")
    func retry_settles_surrender_after_five_failures() async {
        let (prefs, suite) = scratchPreferences()
        defer { teardown(suite) }

        let coordinator = UpdateExitSequence(exitCodes: [1, 1, 1, 1, 1])
        let runner: BrewUpdateManager.Runner = { args in
            if args == ["update"] {
                let code = await coordinator.nextUpdateExit()
                return .ran(exitCode: code, stdout: Data(), stderr: Data())
            }
            if args == ["outdated", "--json=v2"] {
                await coordinator.recordOutdated()
                return .ran(exitCode: 0, stdout: Self.emptyOutdatedJSON, stderr: Data())
            }
            // Post-settle tap-regen probes (tap-info / info) — return
            // success with empty data so the regen step parses-and-bails
            // without polluting the chain-call counters.
            return .ran(exitCode: 0, stdout: Data(), stderr: Data())
        }

        let manager = BrewUpdateManager(
            preferences: prefs, runner: runner,
            sleep: fastSleep, clock: { Date() }
        )
        manager.check()
        await waitForSettle(manager, timeoutSeconds: 3)
        manager.stop()

        #expect(await coordinator.updateCalls == 5)
        #expect(await coordinator.outdatedCalls == 0)
        if case .failed = manager.state {
            // ok
        } else {
            Issue.record("expected .failed after surrender, got \(manager.state)")
        }
    }

    // MARK: - Fail-fast paths

    @Test("fail-fast: binaryNotFound settles immediately with no retries")
    func fail_fast_binary_not_found() async {
        let (prefs, suite) = scratchPreferences()
        defer { teardown(suite) }

        let calls = CallCounter()
        let runner: BrewUpdateManager.Runner = { args in
            await calls.record(args)
            return .binaryNotFound(reason: "test: missing")
        }
        let manager = BrewUpdateManager(
            preferences: prefs, runner: runner,
            sleep: fastSleep, clock: { Date() }
        )
        manager.check()
        await waitForSettle(manager)
        manager.stop()

        let recorded = await calls.recorded
        #expect(recorded.count == 1)
        if case .failed = manager.state { } else {
            Issue.record("expected .failed on binaryNotFound, got \(manager.state)")
        }
    }

    @Test("fail-fast: malformed JSON on zero-exit outdated settles .failed, no retry")
    func fail_fast_malformed_json() async {
        let (prefs, suite) = scratchPreferences()
        defer { teardown(suite) }

        let calls = CallCounter()
        let runner: BrewUpdateManager.Runner = { args in
            await calls.record(args)
            if args == ["outdated", "--json=v2"] {
                return .ran(exitCode: 0,
                            stdout: "not-json".data(using: .utf8)!,
                            stderr: Data())
            }
            return .ran(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let manager = BrewUpdateManager(
            preferences: prefs, runner: runner,
            sleep: fastSleep, clock: { Date() }
        )
        manager.check()
        await waitForSettle(manager)
        manager.stop()

        let recorded = await calls.recorded
        #expect(recorded.count == 2)
        if case .failed = manager.state { } else {
            Issue.record("expected .failed on malformed JSON, got \(manager.state)")
        }
    }

    // MARK: - Settlement writes lastCheckAt

    // MARK: - Tap-cache regen

    /// Helper: a runner that responds to the chain's `update` /
    /// `outdated` calls with success + empty outdated set, and forwards
    /// `tap-info` / `info` calls to the supplied closures. Anything
    /// else returns success-with-empty so the chain doesn't stall.
    private static func regenRunner(
        tapInfo: @escaping @Sendable () async -> RunResult,
        info: @escaping @Sendable ([String]) async -> RunResult
    ) -> BrewUpdateManager.Runner {
        return { args in
            if args == ["tap-info", "--json", "--installed"] {
                return await tapInfo()
            }
            if args.first == "info" {
                return await info(args)
            }
            let stdout = args == ["outdated", "--json=v2"]
                ? Self.emptyOutdatedJSON
                : Data()
            return .ran(exitCode: 0, stdout: stdout, stderr: Data())
        }
    }

    private typealias RunResult = BrewUpdateManager.RunResult

    @Test("tap-regen: happy path runs tap-info then info and writes the cache document")
    func tap_regen_writes_cache_on_success() async {
        let (prefs, suite) = scratchPreferences()
        defer { teardown(suite) }

        let tapInfoJSON = #"""
        [
          {"name":"homebrew/core","formula_names":["git"],"cask_tokens":[]},
          {"name":"cirruslabs/cli","formula_names":["cirruslabs/cli/tart"],"cask_tokens":["cirruslabs/cli/chamber"]}
        ]
        """#.data(using: .utf8)!

        let infoJSON = #"""
        {
          "formulae":[{"name":"tart","full_name":"cirruslabs/cli/tart","tap":"cirruslabs/cli","desc":"Run macOS VMs"}],
          "casks":[{"token":"chamber","full_token":"cirruslabs/cli/chamber","tap":"cirruslabs/cli","desc":null}]
        }
        """#.data(using: .utf8)!

        let infoArgs = TestBox<[String]?>(value: nil)
        let runner = Self.regenRunner(
            tapInfo: { .ran(exitCode: 0, stdout: tapInfoJSON, stderr: Data()) },
            info: { args in
                await infoArgs.set(args)
                return .ran(exitCode: 0, stdout: infoJSON, stderr: Data())
            }
        )

        let written = TestBox<(URL, Data)?>(value: nil)
        let tmpURL = URL(fileURLWithPath: "/tmp/steading-test-\(UUID().uuidString).json")

        let manager = BrewUpdateManager(
            preferences: prefs, runner: runner,
            sleep: fastSleep, clock: { Date() },
            tapIndexCachePathResolver: { tmpURL },
            tapIndexWriter: { url, data in await written.set((url, data)) }
        )
        manager.check()
        await waitForSettle(manager)
        manager.stop()

        // info argv = ["info", "--json=v2"] + the dedup'd union, in
        // first-seen order. homebrew/core is dropped, so "git" doesn't
        // appear; only the cirruslabs/cli entries do.
        #expect(await infoArgs.value == ["info", "--json=v2", "cirruslabs/cli/tart", "cirruslabs/cli/chamber"])
        let writeRecord = await written.value
        #expect(writeRecord?.0 == tmpURL)
        #expect(writeRecord?.1 == infoJSON)
        #expect(manager.state == .idle(count: 0))
    }

    @Test("tap-regen: no user-added taps yields the empty envelope, not a skipped write")
    func tap_regen_no_user_taps_writes_empty_envelope() async {
        let (prefs, suite) = scratchPreferences()
        defer { teardown(suite) }

        let tapInfoJSON = #"""
        [
          {"name":"homebrew/core","formula_names":["git"],"cask_tokens":[]},
          {"name":"homebrew/cask","formula_names":[],"cask_tokens":["firefox"]}
        ]
        """#.data(using: .utf8)!

        let infoCalled = TestBox<Bool>(value: false)
        let runner = Self.regenRunner(
            tapInfo: { .ran(exitCode: 0, stdout: tapInfoJSON, stderr: Data()) },
            info: { _ in
                await infoCalled.set(true)
                return .ran(exitCode: 0, stdout: Data(), stderr: Data())
            }
        )

        let written = TestBox<(URL, Data)?>(value: nil)
        let tmpURL = URL(fileURLWithPath: "/tmp/steading-test-\(UUID().uuidString).json")

        let manager = BrewUpdateManager(
            preferences: prefs, runner: runner,
            sleep: fastSleep, clock: { Date() },
            tapIndexCachePathResolver: { tmpURL },
            tapIndexWriter: { url, data in await written.set((url, data)) }
        )
        manager.check()
        await waitForSettle(manager)
        manager.stop()

        #expect(await infoCalled.value == false)
        let writeRecord = await written.value
        #expect(writeRecord?.0 == tmpURL)
        #expect(String(data: writeRecord?.1 ?? Data(), encoding: .utf8) == #"{"formulae":[],"casks":[]}"#)
    }

    @Test("tap-regen: non-zero brew info exit does not push state into .failed and does not write")
    func tap_regen_info_failure_is_isolated() async {
        let (prefs, suite) = scratchPreferences()
        defer { teardown(suite) }

        let tapInfoJSON = #"""
        [{"name":"cirruslabs/cli","formula_names":["cirruslabs/cli/tart"],"cask_tokens":[]}]
        """#.data(using: .utf8)!

        let written = TestBox<(URL, Data)?>(value: nil)
        let tmpURL = URL(fileURLWithPath: "/tmp/steading-test-\(UUID().uuidString).json")

        let runner = Self.regenRunner(
            tapInfo: { .ran(exitCode: 0, stdout: tapInfoJSON, stderr: Data()) },
            info: { _ in
                .ran(exitCode: 1,
                     stdout: Data(),
                     stderr: "brew info: tap missing".data(using: .utf8)!)
            }
        )

        let manager = BrewUpdateManager(
            preferences: prefs, runner: runner,
            sleep: fastSleep, clock: { Date() },
            tapIndexCachePathResolver: { tmpURL },
            tapIndexWriter: { url, data in await written.set((url, data)) }
        )
        manager.check()
        await waitForSettle(manager)
        manager.stop()

        // State must reflect the *check pipeline's* outcome — .idle —
        // not be polluted by the regen failure.
        #expect(manager.state == .idle(count: 0))
        // Writer never invoked, so any prior cache file on disk is
        // untouched.
        #expect(await written.value == nil)
    }

    @Test("tap-regen: non-zero tap-info exit bails silently before calling brew info")
    func tap_regen_tapInfo_failure_skips_info() async {
        let (prefs, suite) = scratchPreferences()
        defer { teardown(suite) }

        let infoCalled = TestBox<Bool>(value: false)
        let written = TestBox<(URL, Data)?>(value: nil)
        let tmpURL = URL(fileURLWithPath: "/tmp/steading-test-\(UUID().uuidString).json")

        let runner = Self.regenRunner(
            tapInfo: {
                .ran(exitCode: 1,
                     stdout: Data(),
                     stderr: "brew tap-info: not happy".data(using: .utf8)!)
            },
            info: { _ in
                await infoCalled.set(true)
                return .ran(exitCode: 0, stdout: Data(), stderr: Data())
            }
        )

        let manager = BrewUpdateManager(
            preferences: prefs, runner: runner,
            sleep: fastSleep, clock: { Date() },
            tapIndexCachePathResolver: { tmpURL },
            tapIndexWriter: { url, data in await written.set((url, data)) }
        )
        manager.check()
        await waitForSettle(manager)
        manager.stop()

        #expect(manager.state == .idle(count: 0))
        #expect(await infoCalled.value == false)
        #expect(await written.value == nil)
    }

    @Test("tap-regen: malformed tap-info JSON bails silently — state is unaffected")
    func tap_regen_malformed_tap_info_is_isolated() async {
        let (prefs, suite) = scratchPreferences()
        defer { teardown(suite) }

        let infoCalled = TestBox<Bool>(value: false)
        let written = TestBox<(URL, Data)?>(value: nil)
        let tmpURL = URL(fileURLWithPath: "/tmp/steading-test-\(UUID().uuidString).json")

        let runner = Self.regenRunner(
            tapInfo: {
                .ran(exitCode: 0,
                     stdout: "not-json".data(using: .utf8)!,
                     stderr: Data())
            },
            info: { _ in
                await infoCalled.set(true)
                return .ran(exitCode: 0, stdout: Data(), stderr: Data())
            }
        )

        let manager = BrewUpdateManager(
            preferences: prefs, runner: runner,
            sleep: fastSleep, clock: { Date() },
            tapIndexCachePathResolver: { tmpURL },
            tapIndexWriter: { url, data in await written.set((url, data)) }
        )
        manager.check()
        await waitForSettle(manager)
        manager.stop()

        #expect(manager.state == .idle(count: 0))
        #expect(await infoCalled.value == false)
        #expect(await written.value == nil)
    }

    @Test("tap-regen: nil cache-path resolver short-circuits the writer")
    func tap_regen_nil_path_skips_writer() async {
        let (prefs, suite) = scratchPreferences()
        defer { teardown(suite) }

        let tapInfoJSON = #"""
        [{"name":"cirruslabs/cli","formula_names":[],"cask_tokens":[]}]
        """#.data(using: .utf8)!

        let written = TestBox<(URL, Data)?>(value: nil)

        let runner = Self.regenRunner(
            tapInfo: { .ran(exitCode: 0, stdout: tapInfoJSON, stderr: Data()) },
            info: { _ in .ran(exitCode: 0, stdout: Data(), stderr: Data()) }
        )

        let manager = BrewUpdateManager(
            preferences: prefs, runner: runner,
            sleep: fastSleep, clock: { Date() },
            tapIndexCachePathResolver: { nil },
            tapIndexWriter: { url, data in await written.set((url, data)) }
        )
        manager.check()
        await waitForSettle(manager)
        manager.stop()

        #expect(manager.state == .idle(count: 0))
        #expect(await written.value == nil)
    }

    // MARK: - Settlement writes lastCheckAt

    @Test("settlement writes lastCheckAt; pre-chain timestamp is not written during in-flight chain")
    func settlement_writes_lastCheckAt() async {
        let (prefs, suite) = scratchPreferences()
        defer { teardown(suite) }

        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let runner: BrewUpdateManager.Runner = { args in
            let stdout = args == ["outdated", "--json=v2"]
                ? Self.emptyOutdatedJSON
                : Data()
            return .ran(exitCode: 0, stdout: stdout, stderr: Data())
        }
        let manager = BrewUpdateManager(
            preferences: prefs, runner: runner,
            sleep: fastSleep, clock: { fixedNow }
        )
        #expect(prefs.lastCheckAt == nil)
        manager.check()
        await waitForSettle(manager)
        manager.stop()

        #expect(prefs.lastCheckAt == fixedNow)
    }
}

// MARK: - Test helpers (actor-backed; safe across the Runner boundary)

private actor CallCounter {
    private(set) var recorded: [[String]] = []
    func record(_ args: [String]) { recorded.append(args) }
}

/// Single-slot actor wrapper used by tap-regen tests to capture the
/// argv `brew info` was called with and the (URL, Data) pair the
/// writer received, across the runner/writer Sendable boundary.
private actor TestBox<Value: Sendable> {
    private(set) var value: Value
    init(value: Value) { self.value = value }
    func set(_ newValue: Value) { self.value = newValue }
}

private actor UpdateExitSequence {
    private(set) var updateCalls = 0
    private(set) var outdatedCalls = 0
    private let exitCodes: [Int32]

    init(exitCodes: [Int32]) { self.exitCodes = exitCodes }

    func nextUpdateExit() -> Int32 {
        defer { updateCalls += 1 }
        return updateCalls < exitCodes.count ? exitCodes[updateCalls] : 0
    }

    func recordOutdated() { outdatedCalls += 1 }
}

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

    private static let emptyOutdatedJSON = #"{"formulae": [], "casks": []}"#
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
        // One "update" + one "outdated" from the first chain; the
        // extra check() calls MUST NOT have spawned more invocations.
        #expect(recorded.count == 2)
        #expect(recorded[0] == ["update"])
        #expect(recorded[1] == ["outdated", "--json=v2"])
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
            await coordinator.recordOutdated()
            return .ran(exitCode: 0, stdout: Self.emptyOutdatedJSON, stderr: Data())
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
            await coordinator.recordOutdated()
            return .ran(exitCode: 0, stdout: Self.emptyOutdatedJSON, stderr: Data())
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

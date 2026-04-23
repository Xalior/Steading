import Testing
import Foundation
@testable import Steading

/// Covers the Phase 4 sudo-pre-warm wiring in `apply(_:passwordProvider:)`.
/// The real production flow runs; only the sudo subprocess boundary
/// (and the brew subprocess, to avoid an actual upgrade) is
/// substituted via the injectable seams.
@Suite("Brew sudo pre-warm")
@MainActor
struct BrewSudoPreWarmTests {

    private func scratchPreferences() -> (PreferencesStore, String) {
        let suite = "com.xalior.Steading.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (PreferencesStore(defaults: defaults), suite)
    }

    private func teardown(_ suite: String) {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private let fastSleep: BrewUpdateManager.Sleeper = { duration in
        if duration <= .seconds(900) { return }
        try await Task.sleep(for: .seconds(86_400 * 365))
    }

    private let noopNotifier = BrewUpdateManager.BannerNotifier(
        post: { _ in }, removeDelivered: { }
    )

    // MARK: - shouldPromptForPassword (pure)

    @Test("shouldPromptForPassword: Phase 4 always returns true")
    func should_prompt_always_true() {
        let pkg = OutdatedPackage(name: "x", installedVersion: "1",
                                  availableVersion: "2", kind: .cask)
        #expect(BrewUpdateManager.shouldPromptForPassword(markedPackages: []))
        #expect(BrewUpdateManager.shouldPromptForPassword(markedPackages: [pkg]))
        #expect(BrewUpdateManager.shouldPromptForPassword(
            markedPackages: [pkg, pkg, pkg]
        ))
    }

    // MARK: - Wrong password retry / denial

    @Test("three wrong passwords in a row: apply aborts, brew never spawns")
    func three_wrong_passwords_denies() async {
        let (prefs, suite) = scratchPreferences()
        defer { teardown(suite) }

        let preWarmCalls = CallCounter()
        let preWarmer: BrewUpdateManager.PreWarmer = { _ in
            await preWarmCalls.increment()
            return false
        }
        let passwordCalls = CallCounter()
        let provider: BrewUpdateManager.PasswordProvider = {
            await passwordCalls.increment()
            return "wrong"
        }

        let manager = BrewUpdateManager(
            preferences: prefs, sleep: fastSleep, clock: { Date() },
            notifier: noopNotifier, preWarmer: preWarmer
        )
        let pkg = OutdatedPackage(name: "zulu", installedVersion: "1",
                                  availableVersion: "2", kind: .cask)

        manager.apply([pkg], passwordProvider: provider)
        await waitUntil { manager.state != .applying }

        #expect(await preWarmCalls.value == 3)
        #expect(await passwordCalls.value == 3)
        if case .failed = manager.state { } else {
            Issue.record("expected .failed after three wrong passwords, got \(manager.state)")
        }
        #expect(manager.recentApplyOutcome == .adminAccessDenied)
    }

    @Test("modal cancel (nil password) aborts apply without any pre-warm")
    func modal_cancel_aborts() async {
        let (prefs, suite) = scratchPreferences()
        defer { teardown(suite) }

        let preWarmCalls = CallCounter()
        let preWarmer: BrewUpdateManager.PreWarmer = { _ in
            await preWarmCalls.increment()
            return true
        }
        let provider: BrewUpdateManager.PasswordProvider = { nil }

        let manager = BrewUpdateManager(
            preferences: prefs, sleep: fastSleep, clock: { Date() },
            notifier: noopNotifier, preWarmer: preWarmer
        )
        let pkg = OutdatedPackage(name: "zulu", installedVersion: "1",
                                  availableVersion: "2", kind: .cask)

        manager.apply([pkg], passwordProvider: provider)
        await waitUntil { manager.state != .applying }

        #expect(await preWarmCalls.value == 0)
        #expect(manager.recentApplyOutcome == .modalCancelled)
    }

    // MARK: - Password lifecycle

    @Test("after pre-warm the password string is not retained on the manager")
    func password_not_retained() async {
        let (prefs, suite) = scratchPreferences()
        defer { teardown(suite) }

        let secret = "sentinel-\(UUID().uuidString)"
        let preWarmer: BrewUpdateManager.PreWarmer = { _ in true }
        // Brew spawn is a no-op: the apply flow will reach the
        // StreamingProcessRunner step but there's no way to substitute
        // that from here — so we cancel the apply right after pre-warm
        // by asking for the provider to return our secret then returning
        // nil on the (nonexistent) second call.
        let provider: BrewUpdateManager.PasswordProvider = { secret }

        let manager = BrewUpdateManager(
            preferences: prefs, sleep: fastSleep, clock: { Date() },
            notifier: noopNotifier, preWarmer: preWarmer
        )

        // Start apply and cancel immediately; we only care about the
        // pre-warm phase's memory footprint.
        let pkg = OutdatedPackage(name: "zulu", installedVersion: "1",
                                  availableVersion: "2", kind: .cask)
        manager.apply([pkg], passwordProvider: provider)
        // Give apply a beat to finish the pre-warm but cancel before
        // brew actually runs (there's no brew on the test box path
        // mirror, so StreamingProcessRunner will fail fast or we cancel).
        try? await Task.sleep(for: .milliseconds(50))
        manager.cancelApply()
        await waitUntil { manager.state != .applying }

        // Walk the manager's stored properties via Mirror. None of them
        // should hold the sentinel string. If the implementation copies
        // the password into a property, this test finds it.
        let found = Self.mirrorContains(secret, in: manager)
        #expect(!found,
                "password secret was still reachable via Mirror after pre-warm")
    }

    // MARK: - Helpers

    private func waitUntil(_ predicate: () -> Bool,
                           timeoutSeconds: Double = 2.0) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func mirrorContains(_ needle: String, in value: Any) -> Bool {
        let mirror = Mirror(reflecting: value)
        for child in mirror.children {
            if let s = child.value as? String, s.contains(needle) { return true }
            // Descend one level into nested structs and optionals.
            let nested = Mirror(reflecting: child.value)
            for grandchild in nested.children {
                if let s = grandchild.value as? String, s.contains(needle) { return true }
            }
        }
        return false
    }
}

private actor CallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

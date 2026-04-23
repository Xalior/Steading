import Testing
import Foundation
@testable import Steading

/// Stage-1 feasibility tests for the `SUDO_ASKPASS` delivery path.
/// No real brew: `brewPathResolver` points at a fake brew shell
/// script that records the environment it received. No real sudo
/// either in the env-spy test — a second test (`mechanism_sudo_…`)
/// spawns real sudo + real askpass with `POSIX_SPAWN_SETSID` to
/// confirm the no-tty fallback actually fires.
@Suite("Brew sudo askpass — stage 1")
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

    private func waitUntil(_ predicate: () -> Bool,
                           timeoutSeconds: Double = 3.0) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Make a fake brew shell script that dumps its environment and
    /// exits zero — no sudo touched.
    private func installFakeBrew(envLog: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("steading-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let brew = dir.appendingPathComponent("brew")
        let body = """
        #!/bin/sh
        {
          echo "ARGS=$*"
          echo "SUDO_ASKPASS=$SUDO_ASKPASS"
          echo "STEADING_SUDO_PASSWORD=$STEADING_SUDO_PASSWORD"
        } > \(envLog.path)
        exit 0
        """
        try body.write(to: brew, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: brew.path
        )
        return brew
    }

    // MARK: - shouldPromptForPassword (pure)

    @Test("shouldPromptForPassword: stage 1 always returns true")
    func should_prompt_always_true() {
        let pkg = OutdatedPackage(name: "x", installedVersion: "1",
                                  availableVersion: "2", kind: .cask)
        #expect(BrewUpdateManager.shouldPromptForPassword(markedPackages: []))
        #expect(BrewUpdateManager.shouldPromptForPassword(markedPackages: [pkg]))
    }

    // MARK: - Modal cancel path

    @Test("modal cancel aborts apply before brew is spawned")
    func modal_cancel_aborts() async throws {
        let (prefs, suite) = scratchPreferences()
        defer { teardown(suite) }

        let envLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("steading-stage1-envlog-\(UUID().uuidString).txt")
        let fakeBrew = try installFakeBrew(envLog: envLog)

        let manager = BrewUpdateManager(
            preferences: prefs, sleep: fastSleep, clock: { Date() },
            notifier: noopNotifier,
            brewPathResolver: { fakeBrew.path },
            askpassLocator: { URL(fileURLWithPath: "/bin/true") }
        )
        let pkg = OutdatedPackage(name: "zulu", installedVersion: "1",
                                  availableVersion: "2", kind: .cask)

        manager.apply([pkg], passwordProvider: { nil })
        await waitUntil { manager.state != .applying }

        #expect(manager.recentApplyOutcome == .modalCancelled)
        #expect(!FileManager.default.fileExists(atPath: envLog.path),
                "fake brew should NOT have run after a modal cancel")
    }

    // MARK: - Env injection (spy via fake brew)

    @Test("apply sets SUDO_ASKPASS and STEADING_SUDO_PASSWORD on brew's env")
    func env_injection_reaches_brew() async throws {
        let (prefs, suite) = scratchPreferences()
        defer { teardown(suite) }

        let envLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("steading-stage1-envlog-\(UUID().uuidString).txt")
        let fakeBrew = try installFakeBrew(envLog: envLog)
        let askpassURL = URL(fileURLWithPath: "/opt/steading/does-not-exist/askpass.sh")
        let secret = "fake-password-\(UUID().uuidString)"

        let manager = BrewUpdateManager(
            preferences: prefs, sleep: fastSleep, clock: { Date() },
            notifier: noopNotifier,
            brewPathResolver: { fakeBrew.path },
            askpassLocator: { askpassURL }
        )

        let pkg = OutdatedPackage(name: "zulu", installedVersion: "1",
                                  availableVersion: "2", kind: .cask)
        manager.apply([pkg], passwordProvider: { secret })
        await waitUntil { manager.state != .applying && manager.recentApplyOutcome != nil }

        let raw = try String(contentsOf: envLog, encoding: .utf8)
        #expect(raw.contains("SUDO_ASKPASS=\(askpassURL.path)"),
                "fake brew did not receive SUDO_ASKPASS env. Log:\n\(raw)")
        #expect(raw.contains("STEADING_SUDO_PASSWORD=\(secret)"),
                "fake brew did not receive STEADING_SUDO_PASSWORD env. Log:\n\(raw)")
        #expect(raw.contains("ARGS=upgrade zulu"),
                "fake brew received unexpected argv. Log:\n\(raw)")
    }

    // MARK: - Password retention (Mirror probe)

    @Test("password is not retained on the manager after apply completes")
    func password_not_retained_on_manager() async throws {
        let (prefs, suite) = scratchPreferences()
        defer { teardown(suite) }

        let envLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("steading-stage1-envlog-\(UUID().uuidString).txt")
        let fakeBrew = try installFakeBrew(envLog: envLog)
        let secret = "secret-\(UUID().uuidString)"

        let manager = BrewUpdateManager(
            preferences: prefs, sleep: fastSleep, clock: { Date() },
            notifier: noopNotifier,
            brewPathResolver: { fakeBrew.path },
            askpassLocator: { URL(fileURLWithPath: "/bin/true") }
        )

        let pkg = OutdatedPackage(name: "zulu", installedVersion: "1",
                                  availableVersion: "2", kind: .cask)
        manager.apply([pkg], passwordProvider: { secret })
        await waitUntil { manager.state != .applying && manager.recentApplyOutcome != nil }

        // After settle, no property on the manager (or one level deep)
        // should still hold the secret. The env went through the
        // spawned child's stack and was released when the stream
        // finished.
        #expect(!Self.mirrorContains(secret, in: manager),
                "password secret was still reachable via Mirror after apply settled")
    }

    private static func mirrorContains(_ needle: String, in value: Any) -> Bool {
        let mirror = Mirror(reflecting: value)
        for child in mirror.children {
            if let s = child.value as? String, s.contains(needle) { return true }
            let nested = Mirror(reflecting: child.value)
            for grandchild in nested.children {
                if let s = grandchild.value as? String, s.contains(needle) { return true }
            }
        }
        return false
    }
}

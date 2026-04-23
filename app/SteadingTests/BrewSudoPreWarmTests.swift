import Testing
import Foundation
@testable import Steading

/// Stage-2 apply pipeline: the manager spawns brew with
/// `SUDO_ASKPASS` pointing at the injectable helper; no password is
/// collected up front. Tests use a fake brew that records its env.
@Suite("Brew apply — stage 2")
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
        } > \(envLog.path)
        exit 0
        """
        try body.write(to: brew, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: brew.path
        )
        return brew
    }

    private func waitUntil(_ predicate: () -> Bool,
                           timeoutSeconds: Double = 3.0) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("apply sets SUDO_ASKPASS on brew's env when a helper is available")
    func apply_injects_askpass_env() async throws {
        let (prefs, suite) = scratchPreferences()
        defer { teardown(suite) }

        let envLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("steading-stage2-envlog-\(UUID().uuidString).txt")
        let fakeBrew = try installFakeBrew(envLog: envLog)
        let helperPath = "/opt/steading-test/does-not-exist/steading-askpass"

        let manager = BrewUpdateManager(
            preferences: prefs, sleep: fastSleep, clock: { Date() },
            notifier: noopNotifier,
            brewPathResolver: { fakeBrew.path },
            askpassHelperResolver: { helperPath }
        )
        let pkg = OutdatedPackage(name: "zulu", installedVersion: "1",
                                  availableVersion: "2", kind: .cask)

        manager.apply([pkg])
        await waitUntil { manager.state != .applying && manager.recentApplyOutcome != nil }

        let raw = try String(contentsOf: envLog, encoding: .utf8)
        #expect(raw.contains("SUDO_ASKPASS=\(helperPath)"),
                "fake brew did not receive SUDO_ASKPASS env. Log:\n\(raw)")
        #expect(raw.contains("ARGS=upgrade zulu"),
                "fake brew received unexpected argv. Log:\n\(raw)")
    }

    @Test("apply omits SUDO_ASKPASS when no helper is available")
    func apply_omits_askpass_when_no_helper() async throws {
        let (prefs, suite) = scratchPreferences()
        defer { teardown(suite) }

        let envLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("steading-stage2-envlog-\(UUID().uuidString).txt")
        let fakeBrew = try installFakeBrew(envLog: envLog)

        let manager = BrewUpdateManager(
            preferences: prefs, sleep: fastSleep, clock: { Date() },
            notifier: noopNotifier,
            brewPathResolver: { fakeBrew.path },
            askpassHelperResolver: { nil }
        )
        let pkg = OutdatedPackage(name: "zulu", installedVersion: "1",
                                  availableVersion: "2", kind: .cask)

        manager.apply([pkg])
        await waitUntil { manager.state != .applying && manager.recentApplyOutcome != nil }

        let raw = try String(contentsOf: envLog, encoding: .utf8)
        #expect(raw.contains("SUDO_ASKPASS=\n") || raw.contains("SUDO_ASKPASS="),
                "SUDO_ASKPASS should be empty when no helper is available. Log:\n\(raw)")
    }
}

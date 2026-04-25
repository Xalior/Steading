import Testing
import Foundation
@testable import Steading

/// Stage-2 askpass plumbing for the Apply pipeline. After the
/// `BrewUpdateManager` narrowing, the Apply pipeline lives on
/// `BrewPackageManager` — but the env-injection contract is the
/// same: every brew sub-call inherits `SUDO_ASKPASS` pointing at the
/// bundled helper if one is available, and omits the variable when
/// no helper is present so brew falls back to its terminal prompt.
@Suite("Brew apply — stage 2")
@MainActor
struct BrewSudoPreWarmTests {

    private func installFakeBrew(envLog: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("steading-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let brew = dir.appendingPathComponent("brew")
        // Quote $SUDO_ASKPASS so an unset value records as
        // "SUDO_ASKPASS=" rather than reading like a no-op.
        let body = """
        #!/bin/sh
        {
          echo "ARGS=$*"
          echo "SUDO_ASKPASS=${SUDO_ASKPASS}"
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

    private func upgradableRow(_ token: String) -> BrewPackageManager.PackageRow {
        let entry = BrewIndexEntry(
            token: token, fullToken: token,
            tap: "homebrew/core", desc: nil, kind: .formula
        )
        return .init(entry: entry, isInstalled: true, isOutdated: true, isPinned: false)
    }

    @Test("apply sets SUDO_ASKPASS on brew's env when a helper is available")
    func apply_injects_askpass_env() async throws {
        let envLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("steading-stage2-envlog-\(UUID().uuidString).txt")
        let fakeBrew = try installFakeBrew(envLog: envLog)
        let helperPath = "/opt/steading-test/does-not-exist/steading-askpass"

        let runner = BrewPackageManager.defaultSubCallRunner(
            brewPathResolver: { fakeBrew.path },
            askpassHelperResolver: { helperPath }
        )
        let manager = BrewPackageManager(subCallRunner: runner)
        manager.setIndex(rows: [upgradableRow("zulu")], taps: [])
        manager.mark("zulu", true)

        manager.apply()
        await waitUntil { manager.state == .idle && manager.recentApplyOutcome != nil }

        let raw = try String(contentsOf: envLog, encoding: .utf8)
        #expect(raw.contains("SUDO_ASKPASS=\(helperPath)"),
                "fake brew did not receive SUDO_ASKPASS env. Log:\n\(raw)")
        #expect(raw.contains("ARGS=upgrade zulu"),
                "fake brew received unexpected argv. Log:\n\(raw)")
    }

    @Test("apply omits SUDO_ASKPASS when no helper is available")
    func apply_omits_askpass_when_no_helper() async throws {
        let envLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("steading-stage2-envlog-\(UUID().uuidString).txt")
        let fakeBrew = try installFakeBrew(envLog: envLog)

        let runner = BrewPackageManager.defaultSubCallRunner(
            brewPathResolver: { fakeBrew.path },
            askpassHelperResolver: { nil }
        )
        let manager = BrewPackageManager(subCallRunner: runner)
        manager.setIndex(rows: [upgradableRow("zulu")], taps: [])
        manager.mark("zulu", true)

        manager.apply()
        await waitUntil { manager.state == .idle && manager.recentApplyOutcome != nil }

        let raw = try String(contentsOf: envLog, encoding: .utf8)
        // The fake brew echoes "SUDO_ASKPASS=${SUDO_ASKPASS}" — when
        // the variable is unset that prints as the empty string.
        #expect(raw.contains("SUDO_ASKPASS=\n"),
                "SUDO_ASKPASS should be empty when no helper is available. Log:\n\(raw)")
    }
}

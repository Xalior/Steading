import Testing
import Foundation
@testable import Steading

/// Live tests: spawn real `brew tap-info --json --installed` and real
/// `brew info --json=v2 <known-formula>`, parse the output through the
/// production parsers, assert the per-entry fields the package manager
/// keys on are populated. Skipped gracefully if brew isn't on the
/// host, matching `BrewOutdatedLiveTests`.
@Suite("BrewIndex live")
struct BrewIndexLiveTests {

    @Test("live brew tap-info --json --installed parses through production code")
    func live_brew_tap_info() async throws {
        guard hasBrew() else { return }

        let result = await BrewUpdateManager.defaultRunner(["tap-info", "--json", "--installed"])
        switch result {
        case .binaryNotFound(let reason):
            Issue.record("brew was executable but runner reported binaryNotFound: \(reason)")
        case .ran(let exit, let stdout, let stderr):
            #expect(exit == 0,
                    "brew tap-info --json --installed should exit 0; stderr=\(String(data: stderr, encoding: .utf8) ?? "")")
            let taps = try BrewTapInfoParser.parse(stdout)
            // A healthy install always has at least one tap (homebrew/core).
            #expect(!taps.isEmpty)
            for tap in taps {
                #expect(!tap.name.isEmpty)
                // formulaNames + caskTokens are always present (possibly
                // empty), so the parse must have populated both arrays.
                _ = tap.formulaNames
                _ = tap.caskTokens
            }
        }
    }

    @Test("live brew info --json=v2 git decodes through parseInfoEnvelope")
    func live_brew_info_git() async throws {
        guard hasBrew() else { return }

        let result = await BrewUpdateManager.defaultRunner(["info", "--json=v2", "git"])
        switch result {
        case .binaryNotFound(let reason):
            Issue.record("brew was executable but runner reported binaryNotFound: \(reason)")
        case .ran(let exit, let stdout, let stderr):
            #expect(exit == 0,
                    "brew info --json=v2 git should exit 0; stderr=\(String(data: stderr, encoding: .utf8) ?? "")")
            let entries = try BrewIndexParser.parseInfoEnvelope(stdout)
            let git = try #require(entries.first { $0.token == "git" && $0.kind == .formula })
            #expect(git.tap == "homebrew/core")
            #expect(git.fullToken == "git")
            #expect(git.desc?.isEmpty == false)
        }
    }

    private func hasBrew() -> Bool {
        BrewDetector.standardSearchPaths.contains {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }
}

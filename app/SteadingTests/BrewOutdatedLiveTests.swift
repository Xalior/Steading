import Testing
import Foundation
@testable import Steading

/// Live test: invokes the real `brew outdated --json=v2` via the
/// production default runner, parses the result through the real
/// parser, and asserts the shape (not specific package names, which
/// change over time on the dev machine). Skipped gracefully if brew
/// isn't installed.
@Suite("BrewOutdated live")
struct BrewOutdatedLiveTests {

    @Test("live brew outdated --json=v2 parses and returns a shape-valid list")
    func live_brew_outdated() async throws {
        let hasBrew = BrewDetector.standardSearchPaths.contains {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        guard hasBrew else {
            // No brew on this host — treat as a successful skip.
            return
        }

        let result = await BrewUpdateManager.defaultRunner(["outdated", "--json=v2"])
        switch result {
        case .binaryNotFound(let reason):
            Issue.record("brew was executable but runner reported binaryNotFound: \(reason)")
        case .ran(let exit, let stdout, let stderr):
            #expect(exit == 0,
                    "brew outdated --json=v2 should exit 0 on a healthy dev box; stderr=\(String(data: stderr, encoding: .utf8) ?? "")")
            let packages = try BrewOutdatedParser.parse(stdout)
            for p in packages {
                #expect(!p.name.isEmpty)
                #expect(!p.availableVersion.isEmpty)
                #expect(p.kind == .formula || p.kind == .cask)
            }
        }
    }
}

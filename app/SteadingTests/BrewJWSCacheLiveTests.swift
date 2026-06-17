import Testing
import Foundation
@testable import Steading

/// Live test: read brew 6's real consolidated internal index at
/// `~/Library/Caches/Homebrew/api/internal/packages.<tag>.jws.json`,
/// unwrap the envelope, parse through the production parser, and assert
/// known-good core entries decode with the fields the package manager
/// keys on. Skipped gracefully if the file isn't present.
@Suite("BrewJWSCache live")
struct BrewJWSCacheLiveTests {

    @Test("live packages.*.jws.json unwraps and decodes; git + firefox present with non-empty desc")
    func live_packages_index_decodes() throws {
        guard let url = packagesIndexURL() else { return }

        let data = try Data(contentsOf: url)
        let entries = try BrewIndexParser.parsePackagesIndex(data)

        // The index covers all of homebrew/core + homebrew/cask;
        // thousands of entries.
        #expect(entries.count > 100,
                "the internal index should hold the whole core formula + cask universe")

        let git = try #require(entries.first { $0.token == "git" && $0.kind == .formula })
        #expect(git.tap == "homebrew/core")
        #expect(git.fullToken == "git")
        #expect(git.desc?.isEmpty == false)

        let firefox = try #require(entries.first { $0.token == "firefox" && $0.kind == .cask })
        #expect(firefox.tap == "homebrew/cask")
        #expect(firefox.fullToken == "firefox")
        #expect(firefox.desc?.isEmpty == false)
    }

    /// Locate the single `packages.*.jws.json` brew generates for this
    /// host, mirroring the production resolver's glob.
    private func packagesIndexURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(
            "Library/Caches/Homebrew/api/internal/", isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return contents.first { url in
            let name = url.lastPathComponent
            return name.hasPrefix("packages.") && name.hasSuffix(".jws.json")
        }
    }
}

import Testing
import Foundation
@testable import Steading

/// Live tests: read brew's real JWS-format cache files at
/// `~/Library/Caches/Homebrew/api/{formula,cask}.jws.json`, unwrap the
/// envelope, parse through the production parser, assert known-good
/// core entries decode with the fields the package manager keys on.
/// Skipped gracefully if either the brew binary or its cache files
/// aren't present.
@Suite("BrewJWSCache live")
struct BrewJWSCacheLiveTests {

    @Test("live formula.jws.json envelope unwraps and decodes; git is present with non-empty desc")
    func live_formula_jws_decodes_git() throws {
        let url = jwsCacheURL("formula.jws.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let data = try Data(contentsOf: url)
        let entries = try BrewIndexParser.parseJWSFormulae(data)

        // The cache covers all of homebrew/core; thousands of entries.
        #expect(entries.count > 100, "formula.jws.json should hold the whole homebrew/core index")
        let git = try #require(entries.first { $0.token == "git" })
        #expect(git.kind == .formula)
        #expect(git.tap == "homebrew/core")
        #expect(git.fullToken == "git")
        #expect(git.desc?.isEmpty == false)
    }

    @Test("live cask.jws.json envelope unwraps and decodes; firefox is present with non-empty desc")
    func live_cask_jws_decodes_firefox() throws {
        let url = jwsCacheURL("cask.jws.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let data = try Data(contentsOf: url)
        let entries = try BrewIndexParser.parseJWSCasks(data)

        #expect(entries.count > 100, "cask.jws.json should hold the whole homebrew/cask index")
        let firefox = try #require(entries.first { $0.token == "firefox" })
        #expect(firefox.kind == .cask)
        #expect(firefox.tap == "homebrew/cask")
        #expect(firefox.fullToken == "firefox")
        #expect(firefox.desc?.isEmpty == false)
    }

    private func jwsCacheURL(_ filename: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Caches/Homebrew/api/", isDirectory: true)
            .appendingPathComponent(filename)
    }
}

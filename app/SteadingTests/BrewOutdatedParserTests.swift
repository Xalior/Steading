import Testing
import Foundation
@testable import Steading

/// Exercises the real `BrewOutdatedParser.parse` with canned
/// `brew outdated --json=v2` fixtures. Pure function, no I/O.
@Suite("BrewOutdatedParser")
struct BrewOutdatedParserTests {

    // Fixture shapes mirror what `brew outdated --json=v2` actually
    // emits today: `installed_versions` is an array, `current_version`
    // is a string, and formulae additionally carry `pinned` flags.

    @Test("parse: two formulae and one cask yield three OutdatedPackage values")
    func parseTypicalFixture() throws {
        let json = """
        {
          "formulae": [
            {
              "name": "neovim",
              "installed_versions": ["0.12.1"],
              "current_version": "0.12.2",
              "pinned": false,
              "pinned_version": null
            },
            {
              "name": "python@3.11",
              "installed_versions": ["3.11.0"],
              "current_version": "3.11.2",
              "pinned": false,
              "pinned_version": null
            }
          ],
          "casks": [
            {
              "name": "zulu@17",
              "installed_versions": ["17.0.18"],
              "current_version": "17.0.19"
            }
          ]
        }
        """.data(using: .utf8)!

        let packages = try BrewOutdatedParser.parse(json)
        #expect(packages.count == 3)

        let neovim = packages.first { $0.name == "neovim" }
        #expect(neovim?.installedVersion == "0.12.1")
        #expect(neovim?.availableVersion == "0.12.2")
        #expect(neovim?.kind == .formula)

        let python = packages.first { $0.name == "python@3.11" }
        #expect(python?.installedVersion == "3.11.0")
        #expect(python?.availableVersion == "3.11.2")
        #expect(python?.kind == .formula)

        let zulu = packages.first { $0.name == "zulu@17" }
        #expect(zulu?.installedVersion == "17.0.18")
        #expect(zulu?.availableVersion == "17.0.19")
        #expect(zulu?.kind == .cask)
    }

    @Test("parse: empty arrays yield an empty list, not a failure")
    func parseEmpty() throws {
        let json = #"{"formulae": [], "casks": []}"#.data(using: .utf8)!
        let packages = try BrewOutdatedParser.parse(json)
        #expect(packages == [])
    }

    @Test("parse: malformed JSON throws")
    func parseMalformed() {
        let json = "not-even-close-to-json".data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try BrewOutdatedParser.parse(json)
        }
    }

    @Test("parse: JSON missing required fields throws")
    func parseMissingFields() {
        // `current_version` is required; a formula entry without it must
        // fail the decode, not silently drop to nil.
        let json = """
        {"formulae": [{"name": "x", "installed_versions": ["1.0"]}], "casks": []}
        """.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try BrewOutdatedParser.parse(json)
        }
    }
}

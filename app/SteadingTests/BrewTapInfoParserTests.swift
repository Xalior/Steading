import Testing
import Foundation
@testable import Steading

/// Pure-parser tests for `BrewTapInfoParser`, plus the two helpers
/// (`userTaps`, `packageNames`) the tap-regen step composes around it.
/// Inline fixtures match the shape `brew tap-info --json --installed`
/// emits today.
@Suite("BrewTapInfoParser")
struct BrewTapInfoParserTests {

    @Test("parse: representative multi-tap input decodes name + names + tokens for each entry")
    func parse_multiTap() throws {
        let json = #"""
        [
          {
            "name":"homebrew/core",
            "user":"homebrew","repo":"core",
            "installed":true,"official":true,
            "formula_names":["git","jq"],
            "cask_tokens":[]
          },
          {
            "name":"cirruslabs/cli",
            "user":"cirruslabs","repo":"cli",
            "installed":true,"official":false,
            "formula_names":["cirruslabs/cli/tart","cirruslabs/cli/cirrus"],
            "cask_tokens":["cirruslabs/cli/chamber"]
          }
        ]
        """#.data(using: .utf8)!

        let taps = try BrewTapInfoParser.parse(json)

        #expect(taps.count == 2)
        let core = try #require(taps.first { $0.name == "homebrew/core" })
        #expect(core.formulaNames == ["git", "jq"])
        #expect(core.caskTokens == [])

        let cirrus = try #require(taps.first { $0.name == "cirruslabs/cli" })
        #expect(cirrus.formulaNames == ["cirruslabs/cli/tart", "cirruslabs/cli/cirrus"])
        #expect(cirrus.caskTokens == ["cirruslabs/cli/chamber"])
    }

    @Test("parse: empty array decodes to no taps, not a failure")
    func parse_empty() throws {
        let taps = try BrewTapInfoParser.parse("[]".data(using: .utf8)!)
        #expect(taps == [])
    }

    @Test("parse: tap with neither formulae nor casks is decoded with empty lists")
    func parse_emptyTap() throws {
        let json = #"""
        [{"name":"empty/tap","formula_names":[],"cask_tokens":[]}]
        """#.data(using: .utf8)!
        let taps = try BrewTapInfoParser.parse(json)
        #expect(taps == [BrewTapInfo(name: "empty/tap", formulaNames: [], caskTokens: [])])
    }

    @Test("parse: missing required fields throws")
    func parse_missingFields() {
        let bad = #"[{"name":"x"}]"#.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try BrewTapInfoParser.parse(bad)
        }
    }

    // MARK: - userTaps

    @Test("userTaps drops homebrew/core and homebrew/cask")
    func userTaps_dropsCoreAndCask() {
        let taps: [BrewTapInfo] = [
            .init(name: "homebrew/core", formulaNames: [], caskTokens: []),
            .init(name: "homebrew/cask", formulaNames: [], caskTokens: []),
            .init(name: "cirruslabs/cli", formulaNames: ["cirruslabs/cli/tart"], caskTokens: []),
            .init(name: "xalior/steading", formulaNames: [], caskTokens: ["xalior/steading/steading"]),
        ]
        let user = BrewTapInfoParser.userTaps(taps)
        #expect(user.map(\.name) == ["cirruslabs/cli", "xalior/steading"])
    }

    @Test("userTaps yields empty list when only core/cask are installed (the no-non-core boundary)")
    func userTaps_emptyWhenOnlyCore() {
        let taps: [BrewTapInfo] = [
            .init(name: "homebrew/core", formulaNames: [], caskTokens: []),
            .init(name: "homebrew/cask", formulaNames: [], caskTokens: []),
        ]
        #expect(BrewTapInfoParser.userTaps(taps).isEmpty)
    }

    // MARK: - packageNames

    @Test("packageNames unions formula_names and cask_tokens across taps in first-seen order")
    func packageNames_unionAcrossTaps() {
        let taps: [BrewTapInfo] = [
            .init(name: "a/x", formulaNames: ["a/x/one", "a/x/two"], caskTokens: ["a/x/cask1"]),
            .init(name: "b/y", formulaNames: ["b/y/three"], caskTokens: []),
        ]
        #expect(BrewTapInfoParser.packageNames(in: taps) ==
                ["a/x/one", "a/x/two", "a/x/cask1", "b/y/three"])
    }

    @Test("packageNames deduplicates entries that appear more than once")
    func packageNames_deduplicates() {
        let taps: [BrewTapInfo] = [
            .init(name: "a/x", formulaNames: ["a/x/one"], caskTokens: []),
            .init(name: "b/y", formulaNames: ["a/x/one", "b/y/two"], caskTokens: []),
        ]
        #expect(BrewTapInfoParser.packageNames(in: taps) == ["a/x/one", "b/y/two"])
    }

    @Test("packageNames is empty when no taps contribute names")
    func packageNames_empty() {
        let taps: [BrewTapInfo] = [
            .init(name: "a/x", formulaNames: [], caskTokens: []),
        ]
        #expect(BrewTapInfoParser.packageNames(in: taps).isEmpty)
    }
}

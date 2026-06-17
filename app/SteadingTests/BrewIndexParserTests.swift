import Testing
import Foundation
@testable import Steading

/// Pure-parser tests for `BrewIndexParser`. Inline fixtures cover the
/// two on-disk shapes Steading reads:
/// 1. brew 6's consolidated internal index
///    (`api/internal/packages.<tag>.jws.json`) — an envelope-wrapped
///    JSON string whose decoded payload is an *object* with `formulae`
///    / `casks` members keyed by package token,
/// 2. the `{"formulae":[…], "casks":[…]}` envelope brew emits from
///    `brew info --json=v2` and the Steading-owned tap-cache file
///    uses on disk.
@Suite("BrewIndexParser")
struct BrewIndexParserTests {

    // MARK: - Packages index (brew 6 internal)

    @Test("parsePackagesIndex unwraps the envelope and decodes formula + cask entries")
    func parsePackagesIndex_typical() throws {
        let payload = #"""
        {
          "metadata": {"bottle_tag":"arm64_tahoe"},
          "formulae": {
            "git": {"desc":"Distributed revision control system"},
            "jq": {"desc":"Lightweight and flexible command-line JSON processor"}
          },
          "casks": {
            "firefox": {"desc":"Web browser","tap_string":"homebrew/cask"}
          }
        }
        """#
        let entries = try BrewIndexParser.parsePackagesIndex(jwsEnvelope(payload: payload))

        #expect(entries.count == 3)

        let git = try #require(entries.first { $0.token == "git" })
        #expect(git.fullToken == "git")
        #expect(git.tap == "homebrew/core")
        #expect(git.desc == "Distributed revision control system")
        #expect(git.kind == .formula)

        let firefox = try #require(entries.first { $0.token == "firefox" })
        #expect(firefox.fullToken == "firefox")
        #expect(firefox.tap == "homebrew/cask")
        #expect(firefox.desc == "Web browser")
        #expect(firefox.kind == .cask)
    }

    @Test("parsePackagesIndex tolerates a null desc (some formulae have no description)")
    func parsePackagesIndex_nullDesc() throws {
        let payload = #"""
        {"formulae":{"x":{"desc":null}},"casks":{}}
        """#
        let entries = try BrewIndexParser.parsePackagesIndex(jwsEnvelope(payload: payload))
        #expect(entries.first?.desc == nil)
    }

    @Test("parsePackagesIndex falls back to homebrew/cask when a cask omits tap_string")
    func parsePackagesIndex_caskTapFallback() throws {
        let payload = #"""
        {"formulae":{},"casks":{"0-ad":{"desc":"Game"}}}
        """#
        let entries = try BrewIndexParser.parsePackagesIndex(jwsEnvelope(payload: payload))
        let cask = try #require(entries.first { $0.token == "0-ad" })
        #expect(cask.tap == "homebrew/cask")
        #expect(cask.kind == .cask)
    }

    @Test("parsePackagesIndex orders formulae then casks, each sorted by token")
    func parsePackagesIndex_deterministicOrder() throws {
        let payload = #"""
        {"formulae":{"zlib":{"desc":null},"aria2":{"desc":null}},
         "casks":{"zoom":{"desc":null},"alfred":{"desc":null}}}
        """#
        let entries = try BrewIndexParser.parsePackagesIndex(jwsEnvelope(payload: payload))
        #expect(entries.map(\.token) == ["aria2", "zlib", "alfred", "zoom"])
    }

    @Test("parsePackagesIndex throws ParseError.invalidJWSEnvelope when payload field is missing")
    func parsePackagesIndex_missingPayload() {
        let bad = #"{"signatures":[]}"#.data(using: .utf8)!
        #expect(throws: BrewIndexParser.ParseError.invalidJWSEnvelope) {
            _ = try BrewIndexParser.parsePackagesIndex(bad)
        }
    }

    @Test("parsePackagesIndex throws when payload is not a JSON-encoded string")
    func parsePackagesIndex_payloadNotString() {
        let bad = #"{"payload":[1,2,3]}"#.data(using: .utf8)!
        #expect(throws: BrewIndexParser.ParseError.invalidJWSEnvelope) {
            _ = try BrewIndexParser.parsePackagesIndex(bad)
        }
    }

    // MARK: - Info envelope

    @Test("parseInfoEnvelope decodes the {formulae,casks} shape brew info --json=v2 emits")
    func parseInfoEnvelope_typical() throws {
        let json = #"""
        {
          "formulae": [
            {"name":"tart","full_name":"cirruslabs/cli/tart","tap":"cirruslabs/cli","desc":"Run macOS VMs"}
          ],
          "casks": [
            {"token":"firefox","full_token":"firefox","tap":"homebrew/cask","desc":"Web browser"}
          ]
        }
        """#.data(using: .utf8)!

        let entries = try BrewIndexParser.parseInfoEnvelope(json)

        #expect(entries.count == 2)
        let tart = try #require(entries.first { $0.kind == .formula })
        #expect(tart.token == "tart")
        #expect(tart.fullToken == "cirruslabs/cli/tart")
        #expect(tart.tap == "cirruslabs/cli")

        let firefox = try #require(entries.first { $0.kind == .cask })
        #expect(firefox.token == "firefox")
        #expect(firefox.fullToken == "firefox")
        #expect(firefox.tap == "homebrew/cask")
    }

    @Test("parseInfoEnvelope yields an empty list when both arrays are empty")
    func parseInfoEnvelope_empty() throws {
        let json = #"{"formulae":[],"casks":[]}"#.data(using: .utf8)!
        let entries = try BrewIndexParser.parseInfoEnvelope(json)
        #expect(entries == [])
    }

    @Test("parseInfoEnvelope throws on malformed JSON")
    func parseInfoEnvelope_malformed() {
        let bad = "not-json".data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try BrewIndexParser.parseInfoEnvelope(bad)
        }
    }

    // MARK: - Helpers

    /// Wrap a JSON string in a JWS envelope as brew's on-disk caches
    /// do. The envelope's `payload` field is a JSON-encoded *string*
    /// (not a nested object) — encoding it via JSONEncoder reproduces
    /// the same escaping brew uses.
    private func jwsEnvelope(payload: String) -> Data {
        let escaped = String(
            data: try! JSONEncoder().encode(payload),
            encoding: .utf8
        )!
        return #"{"payload":\#(escaped),"signatures":[]}"#.data(using: .utf8)!
    }
}

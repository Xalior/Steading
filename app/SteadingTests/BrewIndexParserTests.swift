import Testing
import Foundation
@testable import Steading

/// Pure-parser tests for `BrewIndexParser`. Inline fixtures cover the
/// three on-disk shapes Steading reads:
/// 1. brew's JWS-format `formula.jws.json` (envelope-wrapped JSON
///    string whose decoded payload is an array of formula entries),
/// 2. brew's JWS-format `cask.jws.json` (same envelope, array of cask
///    entries),
/// 3. the `{"formulae":[…], "casks":[…]}` envelope brew emits from
///    `brew info --json=v2` and the Steading-owned tap-cache file
///    uses on disk.
@Suite("BrewIndexParser")
struct BrewIndexParserTests {

    // MARK: - JWS envelope (formula)

    @Test("parseJWSFormulae unwraps the JWS envelope and decodes formula entries")
    func parseJWSFormulae_typical() throws {
        let payload = #"""
        [
          {"name":"git","full_name":"git","tap":"homebrew/core","desc":"Distributed revision control system"},
          {"name":"jq","full_name":"jq","tap":"homebrew/core","desc":"Lightweight and flexible command-line JSON processor"}
        ]
        """#
        let envelope = jwsEnvelope(payload: payload)

        let entries = try BrewIndexParser.parseJWSFormulae(envelope)

        #expect(entries.count == 2)
        let git = try #require(entries.first { $0.token == "git" })
        #expect(git.fullToken == "git")
        #expect(git.tap == "homebrew/core")
        #expect(git.desc == "Distributed revision control system")
        #expect(git.kind == .formula)
    }

    @Test("parseJWSFormulae tolerates a null desc (some formulae have no description)")
    func parseJWSFormulae_nullDesc() throws {
        let payload = #"""
        [{"name":"x","full_name":"x","tap":"homebrew/core","desc":null}]
        """#
        let entries = try BrewIndexParser.parseJWSFormulae(jwsEnvelope(payload: payload))
        #expect(entries.first?.desc == nil)
    }

    @Test("parseJWSFormulae throws ParseError.invalidJWSEnvelope when payload field is missing")
    func parseJWSFormulae_missingPayload() {
        let bad = #"{"signatures":[]}"#.data(using: .utf8)!
        #expect(throws: BrewIndexParser.ParseError.invalidJWSEnvelope) {
            _ = try BrewIndexParser.parseJWSFormulae(bad)
        }
    }

    @Test("parseJWSFormulae throws when payload is not a JSON-encoded string")
    func parseJWSFormulae_payloadNotString() {
        let bad = #"{"payload":[1,2,3]}"#.data(using: .utf8)!
        #expect(throws: BrewIndexParser.ParseError.invalidJWSEnvelope) {
            _ = try BrewIndexParser.parseJWSFormulae(bad)
        }
    }

    // MARK: - JWS envelope (cask)

    @Test("parseJWSCasks decodes the cask-shape per-entry keys (token / full_token)")
    func parseJWSCasks_typical() throws {
        let payload = #"""
        [
          {"token":"firefox","full_token":"firefox","tap":"homebrew/cask","desc":"Web browser"},
          {"token":"chamber","full_token":"cirruslabs/cli/chamber","tap":"cirruslabs/cli","desc":null}
        ]
        """#
        let entries = try BrewIndexParser.parseJWSCasks(jwsEnvelope(payload: payload))

        #expect(entries.count == 2)
        let chamber = try #require(entries.first { $0.token == "chamber" })
        #expect(chamber.fullToken == "cirruslabs/cli/chamber")
        #expect(chamber.tap == "cirruslabs/cli")
        #expect(chamber.desc == nil)
        #expect(chamber.kind == .cask)
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

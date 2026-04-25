import Foundation

/// One brew package — either a formula or a cask — flattened into a
/// shape the package-manager UI keys on. Decoded from any of three
/// sources by [`BrewIndexParser`](x-source-tag://BrewIndexParser):
/// brew's JWS-format `formula.jws.json`, brew's JWS-format
/// `cask.jws.json`, or a `{"formulae":[…], "casks":[…]}` envelope as
/// emitted by `brew info --json=v2` and used by the Steading-owned
/// tap-cache file.
struct BrewIndexEntry: Sendable, Hashable {
    enum Kind: String, Sendable, Hashable {
        case formula
        case cask
    }

    /// `name` for formulae, `token` for casks — the identifier brew's
    /// CLI accepts.
    let token: String

    /// `full_name` for formulae, `full_token` for casks — qualified
    /// with the source tap when not in `homebrew/core` /
    /// `homebrew/cask`.
    let fullToken: String

    /// Source tap (e.g. `homebrew/core`, `cirruslabs/cli`).
    let tap: String

    /// Short description. Some entries have this null in brew's data;
    /// kept optional rather than coerced to empty so the UI can choose
    /// whether to render a placeholder.
    let desc: String?

    let kind: Kind
}

/// Pure parser for brew's package-index JSON. Three entry points cover
/// the three on-disk shapes Steading consumes:
///
/// - `parseJWSFormulae(_:)` — `~/Library/Caches/Homebrew/api/formula.jws.json`
/// - `parseJWSCasks(_:)`    — `~/Library/Caches/Homebrew/api/cask.jws.json`
/// - `parseInfoEnvelope(_:)` — `brew info --json=v2` output and the
///   Steading-owned tap-cache file
///
/// The JWS envelope's `payload` field is itself a JSON-encoded *string*
/// (not a nested object) — decoding it is a two-step unwrap.
enum BrewIndexParser {

    enum ParseError: Error, Equatable {
        case invalidJWSEnvelope
    }

    private struct JWSEnvelope: Decodable {
        let payload: String
    }

    private struct InfoEnvelope: Decodable {
        let formulae: [FormulaDTO]
        let casks: [CaskDTO]
    }

    private struct FormulaDTO: Decodable {
        let name: String
        let fullName: String
        let tap: String
        let desc: String?

        enum CodingKeys: String, CodingKey {
            case name
            case fullName = "full_name"
            case tap
            case desc
        }
    }

    private struct CaskDTO: Decodable {
        let token: String
        let fullToken: String
        let tap: String
        let desc: String?

        enum CodingKeys: String, CodingKey {
            case token
            case fullToken = "full_token"
            case tap
            case desc
        }
    }

    static func parseJWSFormulae(_ data: Data) throws -> [BrewIndexEntry] {
        let payload = try unwrapJWSPayload(data)
        let dtos = try JSONDecoder().decode([FormulaDTO].self, from: payload)
        return dtos.map(toEntry(_:))
    }

    static func parseJWSCasks(_ data: Data) throws -> [BrewIndexEntry] {
        let payload = try unwrapJWSPayload(data)
        let dtos = try JSONDecoder().decode([CaskDTO].self, from: payload)
        return dtos.map(toEntry(_:))
    }

    static func parseInfoEnvelope(_ data: Data) throws -> [BrewIndexEntry] {
        let envelope = try JSONDecoder().decode(InfoEnvelope.self, from: data)
        return envelope.formulae.map(toEntry(_:)) + envelope.casks.map(toEntry(_:))
    }

    private static func unwrapJWSPayload(_ data: Data) throws -> Data {
        let envelope: JWSEnvelope
        do {
            envelope = try JSONDecoder().decode(JWSEnvelope.self, from: data)
        } catch {
            throw ParseError.invalidJWSEnvelope
        }
        guard let payload = envelope.payload.data(using: .utf8) else {
            throw ParseError.invalidJWSEnvelope
        }
        return payload
    }

    private static func toEntry(_ dto: FormulaDTO) -> BrewIndexEntry {
        BrewIndexEntry(
            token: dto.name,
            fullToken: dto.fullName,
            tap: dto.tap,
            desc: dto.desc,
            kind: .formula
        )
    }

    private static func toEntry(_ dto: CaskDTO) -> BrewIndexEntry {
        BrewIndexEntry(
            token: dto.token,
            fullToken: dto.fullToken,
            tap: dto.tap,
            desc: dto.desc,
            kind: .cask
        )
    }
}

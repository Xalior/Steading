import Foundation

/// One brew package — either a formula or a cask — flattened into a
/// shape the package-manager UI keys on. Decoded from one of two
/// sources by [`BrewIndexParser`](x-source-tag://BrewIndexParser):
/// brew's JWS-format internal index
/// (`~/Library/Caches/Homebrew/api/internal/packages.<tag>.jws.json`),
/// or a `{"formulae":[…], "casks":[…]}` envelope as emitted by
/// `brew info --json=v2` and used by the Steading-owned tap-cache file.
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

/// Pure parser for brew's package-index JSON. Two entry points cover
/// the two on-disk shapes Steading consumes:
///
/// - `parsePackagesIndex(_:)` — brew 6's consolidated internal index
///   `~/Library/Caches/Homebrew/api/internal/packages.<tag>.jws.json`
/// - `parseInfoEnvelope(_:)` — `brew info --json=v2` output and the
///   Steading-owned tap-cache file
///
/// The JWS envelope's `payload` field is itself a JSON-encoded *string*
/// (not a nested object) — decoding it is a two-step unwrap. In brew
/// 6's internal index the decoded payload is an *object* whose
/// `formulae` / `casks` members are dictionaries keyed by the package
/// name/token; the key is the identifier (entries carry no `name` of
/// their own), the tap is implicit (`homebrew/core` for formulae) or
/// carried as `tap_string` (casks). The index covers
/// `homebrew/core` + `homebrew/cask` only — third-party taps reach the
/// universe through `parseInfoEnvelope` and the Steading tap-cache.
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

    /// brew 6 internal-index payload: `formulae` / `casks` are objects
    /// keyed by the package identifier. Only the fields the universe
    /// keys on are decoded; the per-entry payload carries no name/tap,
    /// so the dictionary key supplies the token.
    private struct PackagesIndex: Decodable {
        let formulae: [String: PackageEntryDTO]
        let casks: [String: CaskEntryDTO]
    }

    private struct PackageEntryDTO: Decodable {
        let desc: String?
    }

    private struct CaskEntryDTO: Decodable {
        let desc: String?
        let tapString: String?

        enum CodingKeys: String, CodingKey {
            case desc
            case tapString = "tap_string"
        }
    }

    /// Parse brew 6's consolidated internal index. The key of each
    /// `formulae` / `casks` entry is the token; formulae are
    /// `homebrew/core`, casks default to `homebrew/cask` unless the
    /// entry's `tap_string` says otherwise. `fullToken` equals the
    /// token (the index is core-only). Entries are sorted — formulae
    /// then casks, each by token — so dict-decode order doesn't leak
    /// into the universe.
    static func parsePackagesIndex(_ data: Data) throws -> [BrewIndexEntry] {
        let payload = try unwrapJWSPayload(data)
        let index = try JSONDecoder().decode(PackagesIndex.self, from: payload)
        let formulae = index.formulae
            .sorted { $0.key < $1.key }
            .map { token, dto in
                BrewIndexEntry(token: token, fullToken: token,
                               tap: "homebrew/core", desc: dto.desc,
                               kind: .formula)
            }
        let casks = index.casks
            .sorted { $0.key < $1.key }
            .map { token, dto in
                BrewIndexEntry(token: token, fullToken: token,
                               tap: dto.tapString ?? "homebrew/cask",
                               desc: dto.desc, kind: .cask)
            }
        return formulae + casks
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

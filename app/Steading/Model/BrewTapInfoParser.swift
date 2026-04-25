import Foundation

/// One row of `brew tap-info --json --installed`, narrowed to the
/// fields the tap-regen step needs.
struct BrewTapInfo: Sendable, Hashable {
    /// Qualified tap name in `<user>/<repo>` form, e.g.
    /// `homebrew/core`, `cirruslabs/cli`.
    let name: String

    /// Fully-qualified formula identifiers contributed by this tap,
    /// e.g. `cirruslabs/cli/tart`.
    let formulaNames: [String]

    /// Fully-qualified cask identifiers contributed by this tap,
    /// e.g. `cirruslabs/cli/chamber`.
    let caskTokens: [String]
}

/// Pure parser for `brew tap-info --json --installed`. The output is a
/// JSON array; each entry has many fields, only a subset of which the
/// tap-regen step cares about.
enum BrewTapInfoParser {

    private struct DTO: Decodable {
        let name: String
        let formulaNames: [String]
        let caskTokens: [String]

        enum CodingKeys: String, CodingKey {
            case name
            case formulaNames = "formula_names"
            case caskTokens = "cask_tokens"
        }
    }

    static func parse(_ data: Data) throws -> [BrewTapInfo] {
        let dtos = try JSONDecoder().decode([DTO].self, from: data)
        return dtos.map { dto in
            BrewTapInfo(
                name: dto.name,
                formulaNames: dto.formulaNames,
                caskTokens: dto.caskTokens
            )
        }
    }

    /// Filter to taps the tap-regen step targets — everything except
    /// `homebrew/core` and `homebrew/cask`, which are covered by
    /// brew's own JWS cache.
    static func userTaps(_ taps: [BrewTapInfo]) -> [BrewTapInfo] {
        taps.filter { $0.name != "homebrew/core" && $0.name != "homebrew/cask" }
    }

    /// Union of `formula_names` and `cask_tokens` across the given
    /// taps, deduplicated, in first-seen order — the argv tail for
    /// `brew info --json=v2 …`.
    static func packageNames(in taps: [BrewTapInfo]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tap in taps {
            for name in tap.formulaNames + tap.caskTokens
            where seen.insert(name).inserted {
                result.append(name)
            }
        }
        return result
    }
}

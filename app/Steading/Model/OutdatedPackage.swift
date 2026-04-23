import Foundation

/// One entry returned by `brew outdated --json=v2`, normalised so the
/// UI and the apply pipeline can treat formulae and casks uniformly.
struct OutdatedPackage: Sendable, Hashable {
    enum Kind: String, Sendable, Hashable {
        case formula
        case cask
    }

    let name: String
    let installedVersion: String
    let availableVersion: String
    let kind: Kind
}

/// Pure parser for the `brew outdated --json=v2` payload. Tests call
/// this directly with canned fixtures; the manager calls it with real
/// brew output.
enum BrewOutdatedParser {

    private struct Payload: Decodable {
        let formulae: [Entry]
        let casks: [Entry]
    }

    private struct Entry: Decodable {
        let name: String
        let installedVersions: [String]
        let currentVersion: String
    }

    static func parse(_ data: Data) throws -> [OutdatedPackage] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(Payload.self, from: data)

        let formulae = payload.formulae.map {
            OutdatedPackage(
                name: $0.name,
                installedVersion: $0.installedVersions.first ?? "",
                availableVersion: $0.currentVersion,
                kind: .formula
            )
        }
        let casks = payload.casks.map {
            OutdatedPackage(
                name: $0.name,
                installedVersion: $0.installedVersions.first ?? "",
                availableVersion: $0.currentVersion,
                kind: .cask
            )
        }
        return formulae + casks
    }
}

import Foundation

/// A single entry in one of Steading's three catalogs — services,
/// webapps, or macOS built-ins. Dummy data for the PoC; real catalog
/// entries will be loaded from per-item definition files (see
/// DESIGN.md § Definition files).
struct CatalogItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable, Hashable {
        case service
        case webapp
        case builtIn

        var label: String {
            switch self {
            case .service:  return "Service"
            case .webapp:   return "Webapp"
            case .builtIn:  return "macOS Built-in"
            }
        }
    }

    let id: String
    let kind: Kind
    let name: String
    /// SF Symbol name.
    let symbol: String
    let subtitle: String
    let summary: String
    /// Display names of entries this item depends on (dummy data).
    let dependencies: [String]
    /// True for optional catalog entries (e.g. Tailscale, Stalwart).
    let optional: Bool
}

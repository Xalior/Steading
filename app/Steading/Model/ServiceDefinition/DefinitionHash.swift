import Foundation
import CryptoKit

/// Content hashing for service-definition YAMLs.
///
/// SHA-256 over the file's raw bytes. Used identically by:
///
/// - the build-phase validator that writes `.bundle-hashes.plist`
/// - the runtime `BundleDefinitionVerifier` that reads that plist
/// - the helper's approvals store, which keys consent records by
///   `(yamlPath, hash)`.
///
/// Single source of truth so the three callers can't disagree.
public enum DefinitionHash {

    /// Lower-case hexadecimal SHA-256 of `bytes`.
    public static func sha256Hex(_ bytes: Data) -> String {
        let digest = SHA256.hash(data: bytes)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Convenience wrapper that hashes a UTF-8 string.
    public static func sha256Hex(of source: String) -> String {
        sha256Hex(Data(source.utf8))
    }
}

/// On-disk shape of `.bundle-hashes.plist`. Keyed by the YAML's
/// filename relative to the `ServiceDefinitions/` directory (e.g.
/// `mysql.yml`); valued by lower-case hex SHA-256.
///
/// The plist itself is covered by the app's codesign envelope
/// (Resources/* are sealed in `_CodeSignature/CodeResources`), so
/// modifying it without re-signing breaks the signature — which is
/// the whole point of build-time hashes vs. runtime computation.
public struct BundleHashList: Codable, Equatable, Sendable {
    public var entries: [String: String]
    public init(_ entries: [String: String] = [:]) { self.entries = entries }

    /// Reads the plist from `url`. Returns an empty list when the
    /// file is absent (a release-mode oversight or a developer who
    /// hasn't run the build phase yet — the verifier surfaces that
    /// as every YAML being `.unrecorded`).
    public static func read(from url: URL) throws -> BundleHashList {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return BundleHashList()
        }
        let data = try Data(contentsOf: url)
        let decoder = PropertyListDecoder()
        let payload = try decoder.decode([String: String].self, from: data)
        return BundleHashList(payload)
    }

    /// Writes the plist atomically to `url`.
    public func write(to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(entries)
        try data.write(to: url, options: .atomic)
    }
}

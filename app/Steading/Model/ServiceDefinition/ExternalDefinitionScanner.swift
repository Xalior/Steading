import Foundation

/// Scans an external data directory for service-definition YAMLs the
/// owner has dropped in (or replacements for built-ins).
///
/// External YAMLs whose `serviceID` matches a built-in *replace* the
/// built-in for the duration of the runtime; this is intentional
/// power-user extensibility per the plan, and the entire reason the
/// consent gate exists.
public enum ExternalDefinitionScanner {

    public struct Entry: Equatable, Sendable {
        public let url: URL
        public let source: String
        public let hash: String
    }

    /// Read every `*.yml` under `directory` (non-recursive) and
    /// return one `Entry` per file. Missing directory yields `[]`;
    /// individual unreadable files surface through `throws`.
    public static func scan(directory: URL) throws -> [Entry] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }

        let names = try fm.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".yml") }
            .sorted()

        var entries: [Entry] = []
        for name in names {
            let url = directory.appendingPathComponent(name)
            let data = try Data(contentsOf: url)
            guard let source = String(data: data, encoding: .utf8) else {
                continue
            }
            let hash = DefinitionHash.sha256Hex(data)
            entries.append(Entry(url: url, source: source, hash: hash))
        }
        return entries
    }
}

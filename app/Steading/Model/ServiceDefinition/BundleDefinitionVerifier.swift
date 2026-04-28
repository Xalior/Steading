import Foundation

/// Re-hashes every YAML in the bundle's `ServiceDefinitions/`
/// directory at app launch and compares against
/// `.bundle-hashes.plist`. Partitions the YAMLs into:
///
/// - **matched** — bundle YAML matches its recorded build-time hash.
///   These load as trusted; no consent prompt.
/// - **mismatched** — bundle YAML on disk doesn't match the recorded
///   hash. Treated as externally-supplied; consent gate fires.
/// - **unrecorded** — bundle YAML present on disk but absent from
///   `.bundle-hashes.plist`. Same gate as mismatched.
/// - **missing** — listed in the plist but not on disk. Surface for
///   diagnostic logging; not a security event.
///
/// Pure logic; no I/O the caller can't intercept by passing in
/// (`directory:`, `hashListURL:`).
public enum BundleDefinitionVerifier {

    public struct Partition: Equatable, Sendable {
        public var matched: [String]
        public var mismatched: [String]
        public var unrecorded: [String]
        public var missing: [String]

        public init(matched: [String] = [],
                    mismatched: [String] = [],
                    unrecorded: [String] = [],
                    missing: [String] = []) {
            self.matched = matched
            self.mismatched = mismatched
            self.unrecorded = unrecorded
            self.missing = missing
        }
    }

    /// Walk `directory`, hash every `*.yml` in it, and partition
    /// against `hashListURL`'s `.bundle-hashes.plist`. Filenames in
    /// every partition are basenames (e.g. `mysql.yml`), sorted.
    public static func verify(directory: URL, hashListURL: URL) throws -> Partition {
        let hashList = try BundleHashList.read(from: hashListURL)
        return try verify(directory: directory, hashList: hashList)
    }

    /// Pure overload taking a pre-loaded `BundleHashList`. Used by
    /// tests that hand-build the expected hash map.
    public static func verify(directory: URL, hashList: BundleHashList) throws -> Partition {
        let fm = FileManager.default
        let isDir = (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        guard isDir else {
            return Partition(missing: hashList.entries.keys.sorted())
        }

        let names = try fm.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".yml") }
            .sorted()

        var partition = Partition()
        var seen = Set<String>()
        for name in names {
            seen.insert(name)
            let url = directory.appendingPathComponent(name)
            let bytes = try Data(contentsOf: url)
            let actual = DefinitionHash.sha256Hex(bytes)
            if let expected = hashList.entries[name] {
                if expected == actual {
                    partition.matched.append(name)
                } else {
                    partition.mismatched.append(name)
                }
            } else {
                partition.unrecorded.append(name)
            }
        }

        for name in hashList.entries.keys.sorted() where !seen.contains(name) {
            partition.missing.append(name)
        }
        return partition
    }
}

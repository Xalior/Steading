import Foundation
import Darwin

#if STEADING_TEST_HOST
@testable import Steading
#endif

/// Helper-side persistence for the consent system.
///
/// Stored at `SteadingApprovalsPlistPath`
/// (`/Library/Application Support/Steading/approvals.plist`),
/// `root:wheel`, mode `0600`. Only the helper (running as root) can
/// read or write it. Every mutation goes through the helper's
/// `recordApproval` / `forgetApproval` XPC methods, gated by the
/// existing mutual codesign pin — the local-attacker "drop a YAML
/// and forge an approval" path requires either defeating that pin
/// or staging the live admin-password challenge.
///
/// On-disk shape: a plist dictionary mapping `yamlPath` (absolute
/// path on disk) → SHA-256 hex of the approved content. One entry
/// per YAML; not stacked.
public enum ApprovalsStore {

    /// Read the plist from `url`. Returns an empty dictionary when
    /// the file is absent (first run). Read-failure surfaces
    /// upstream; the helper logs and returns "no approval" for
    /// every check rather than crashing.
    public static func read(from url: URL = URL(fileURLWithPath: SteadingApprovalsPlistPath))
        throws -> [String: String]
    {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [:]
        }
        let data = try Data(contentsOf: url)
        let decoder = PropertyListDecoder()
        return try decoder.decode([String: String].self, from: data)
    }

    /// Atomically write `entries` to `url`. When running as root,
    /// `fchmod`s to `0600` and `fchown`s to `root:wheel` before the
    /// rename so an attacker can't race a partial-state file.
    public static func write(_ entries: [String: String],
                             to url: URL = URL(fileURLWithPath: SteadingApprovalsPlistPath)) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(entries)

        let tempPath = "\(dir.path)/.\(url.lastPathComponent).steading-new.\(getpid())"
        let fd = open(tempPath, O_WRONLY | O_CREAT | O_TRUNC | O_EXCL, 0o600)
        guard fd >= 0 else {
            throw NSError(domain: "ApprovalsStore", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey:
                                     "open temp \(tempPath): \(String(cString: strerror(errno)))"])
        }
        defer { close(fd) }
        if geteuid() == 0, fchown(fd, 0, 0) != 0 {
            unlink(tempPath)
            throw NSError(domain: "ApprovalsStore", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey:
                                     "fchown: \(String(cString: strerror(errno)))"])
        }
        try data.withUnsafeBytes { buf in
            var offset = 0
            var remaining = data.count
            while remaining > 0 {
                let written = Darwin.write(fd, buf.baseAddress!.advanced(by: offset), remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    let err = String(cString: strerror(errno))
                    unlink(tempPath)
                    throw NSError(domain: "ApprovalsStore", code: Int(errno),
                                  userInfo: [NSLocalizedDescriptionKey: "write: \(err)"])
                }
                offset += written
                remaining -= written
            }
        }
        if rename(tempPath, url.path) != 0 {
            let err = String(cString: strerror(errno))
            unlink(tempPath)
            throw NSError(domain: "ApprovalsStore", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "rename: \(err)"])
        }
    }

    /// Add or replace an approval. Pure on the in-memory map; the
    /// caller persists.
    public static func record(_ entries: inout [String: String],
                              yamlPath: String,
                              hash: String) {
        entries[yamlPath] = hash
    }

    /// Drop an approval. No-op when absent.
    public static func forget(_ entries: inout [String: String], yamlPath: String) {
        entries.removeValue(forKey: yamlPath)
    }

    /// Whether `(yamlPath, hash)` matches a recorded approval.
    public static func isApproved(_ entries: [String: String],
                                  yamlPath: String,
                                  hash: String) -> Bool {
        entries[yamlPath] == hash
    }

    /// True when *any* recorded entry has the given hash. Used by
    /// helper-side write methods that receive `yamlHash` without the
    /// path: a write is approved as long as at least one recorded
    /// YAML matches the hash.
    public static func anyApproval(_ entries: [String: String],
                                   matchesHash hash: String) -> Bool {
        entries.values.contains(hash)
    }
}

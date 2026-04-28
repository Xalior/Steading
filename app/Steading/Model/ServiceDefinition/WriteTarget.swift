import Foundation

/// A file or directory the install pipeline writes for a service —
/// declared in YAML, surfaced verbatim in the consent gate, and
/// passed through XPC alongside the YAML's content hash so the
/// helper can verify it derives from approved YAML.
///
/// Three flavours, in order of preference per the plan:
///
/// - `.literal` — exact path. Tightest, most audit-legible.
/// - `.template` — path with named placeholders constrained by
///   per-placeholder validation rules. Right when the *shape* of
///   the path is fixed but the value varies (e.g. Caddy per-vhost
///   config).
/// - `.directory` — directory under which any file may be written.
///   Loosest; reserved for cases where neither of the above fits.
public struct WriteTarget: Codable, Equatable, Sendable {

    /// Stable id used to wire wizard fields to write targets and to
    /// identify a target in pipeline log lines.
    public let id: String

    public let kind: Kind

    /// For `.literal` and `.template`: the path or template. For
    /// `.directory`: the directory root.
    public let path: String

    /// File mode (octal in YAML, e.g. `0644`).
    public let mode: Int

    /// Owner UID for the file or directory at write time. `nil`
    /// means leave whatever the caller's uid maps to (used for
    /// helper-process inherited ownership).
    public let ownerUID: Int?

    /// Owner GID; same semantics as `ownerUID`.
    public let groupGID: Int?

    /// Hard cap on the bytes the helper will accept for this target.
    /// Per-target so a config file gets a tight cap and a log
    /// directory's data files get a looser one.
    public let sizeCapBytes: Int?

    /// For `.template`: per-placeholder validation rules keyed by
    /// placeholder name. Required for templates; ignored otherwise.
    public let placeholders: [String: Validation]?

    public enum Kind: String, Codable, Equatable, Sendable {
        case literal
        case template
        case directory
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, path, mode, ownerUID, groupGID, sizeCapBytes, placeholders
    }
}

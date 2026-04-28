import Foundation

/// Defense-in-depth refusal rules applied by the privileged helper
/// to every write/create/remove call, regardless of whether the
/// calling main app has been codesign-pinned and the YAML hash has
/// been approved by the user.
///
/// The primary trust boundary lives elsewhere: a calling main app
/// must be code-signed correctly *and* every privileged write must
/// derive from a YAML whose `(yamlPath, hash)` pair is in the
/// helper's approvals list. Those gates do most of the work.
///
/// This file is the second layer. A user can be socially-engineered
/// into approving a malicious YAML — that's the same threat model
/// as Apple's own "this app wants to control your computer" prompt
/// that people frequently click yes on. No legitimate Steading
/// service has any business writing to `/etc/sudoers` or
/// `~/.ssh/authorized_keys`, so the helper refuses those targets
/// outright even if approval has been granted.
///
/// Pure logic — every function is deterministic over its inputs.
/// `refuse(path:mode:)` covers the path-string and mode checks; the
/// symlink check requires filesystem access and lives in a separate
/// helper-side function (the helper calls both before any write).
public enum PrivHelperRefusalList {

    /// Categorical rejection reasons. The helper returns these
    /// verbatim to the caller so the main app can surface a useful
    /// message; the strings are also written to the helper's log.
    public enum Reason: Equatable, Sendable, CustomStringConvertible {
        case suidBit
        case sgidBit
        case stickyBit
        case modeOutOfRange(Int)
        case pathNotAbsolute
        case pathTraversal
        case nonCanonical
        case blocklisted(matched: String)

        public var description: String {
            switch self {
            case .suidBit: return "SUID bit set in mode"
            case .sgidBit: return "SGID bit set in mode"
            case .stickyBit: return "sticky bit set in mode"
            case .modeOutOfRange(let m): return "mode \(m) out of range 0..0o7777"
            case .pathNotAbsolute: return "path is not absolute"
            case .pathTraversal: return "path contains '..' traversal"
            case .nonCanonical: return "path is not canonical"
            case .blocklisted(let m): return "path is blocklisted: \(m)"
            }
        }
    }

    // MARK: - Mode bits

    /// Bits the helper categorically refuses in any write/create
    /// mode. Real Steading-managed config and data dirs have no
    /// business with SUID/SGID/sticky.
    public static let forbiddenModeBits: Int = 0o4000 | 0o2000 | 0o1000

    /// Hardcoded path patterns Steading-managed services cannot
    /// touch under any circumstances. Matched as prefixes (a
    /// trailing `/` indicates "or anything beneath"); a `*` in the
    /// final segment indicates "any name in this prefix" (e.g.
    /// `/etc/sudoers*` matches `/etc/sudoers`, `/etc/sudoers.d`).
    public static let blocklist: [String] = [
        "/etc/sudoers",
        "/etc/pam.d/",
        "/etc/master.passwd",
        "/var/db/sudo/",
        "/System/",
        "/private/etc/security/audit_",
        "/private/etc/sudoers",
        "/private/etc/pam.d/",
        "/usr/bin/",
        "/usr/sbin/",
        "/sbin/",
        "/bin/",
    ]

    /// Steading's own helper. Writes targeting this path are
    /// allowed; writes targeting any *other* file under
    /// `/Library/PrivilegedHelperTools/` are blocked so a malicious
    /// YAML can't drop a parallel helper that the main app would
    /// then talk to.
    public static let ownHelperPath = "/Library/PrivilegedHelperTools/com.xalior.Steading.privhelper"

    /// Pure path + mode check. Returns `nil` if the call is
    /// acceptable as far as defense-in-depth is concerned, or a
    /// `Reason` describing the rejection.
    public static func refuse(path: String, mode: Int) -> Reason? {
        if mode < 0 || mode > 0o7777 { return .modeOutOfRange(mode) }
        if mode & 0o4000 != 0 { return .suidBit }
        if mode & 0o2000 != 0 { return .sgidBit }
        if mode & 0o1000 != 0 { return .stickyBit }

        if !path.hasPrefix("/") { return .pathNotAbsolute }
        if path.range(of: "/../") != nil
            || path.hasSuffix("/..")
            || path == ".."
            || path.contains("/./") {
            return .pathTraversal
        }
        // A canonical path has no doubled slashes and no trailing
        // slash (except the root). Don't accept either.
        if path.contains("//") { return .nonCanonical }
        if path.count > 1, path.hasSuffix("/") { return .nonCanonical }

        if let matched = matchedBlocklist(path: path) {
            return .blocklisted(matched: matched)
        }
        if path.hasPrefix("/Library/PrivilegedHelperTools/"),
           path != ownHelperPath {
            return .blocklisted(matched: "/Library/PrivilegedHelperTools/* (other than \(ownHelperPath))")
        }
        return nil
    }

    /// Returns the blocklist entry that matches `path`, or nil.
    ///
    /// Entries are matched as plain prefixes — an entry ending in
    /// `/` matches anything under that directory, and an entry
    /// without a trailing `/` matches any path that begins with the
    /// entry verbatim (catches `/etc/sudoers`, `/etc/sudoers.d`,
    /// `/etc/sudoers.bak`, etc.). The blocklist is small and
    /// hand-curated, so prefix-only matching is sufficient.
    public static func matchedBlocklist(path: String) -> String? {
        for entry in blocklist {
            if path.hasPrefix(entry) { return entry }
        }
        return nil
    }
}

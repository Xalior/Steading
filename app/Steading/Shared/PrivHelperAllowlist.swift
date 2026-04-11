import Foundation

/// Strict allowlist of command-line tools the privileged helper is
/// willing to run. The helper refuses any executable outside this set.
///
/// This is the security boundary between the main Steading app and
/// root. If the helper accepts an arbitrary executable, every client
/// that passes the code-sign check effectively has root shell
/// execution. Instead, the helper only knows about the handful of
/// first-party macOS tools the v1 built-in services UI needs.
///
/// Adding a new built-in service means adding its underlying tool
/// here and (if appropriate) gating specific arguments. Never open
/// the allowlist up to "any binary under /usr/sbin" — that defeats
/// the point.
enum PrivHelperAllowlist {

    /// Absolute paths of allowed executables.
    static let allowedExecutables: Set<String> = [
        "/usr/sbin/systemsetup",
        "/bin/launchctl",
        "/usr/bin/AssetCacheManagerUtil",
        "/usr/libexec/ApplicationFirewall/socketfilterfw",
        "/usr/sbin/cupsctl",
        "/usr/bin/pmset",
    ]

    /// Pure check exposed for direct testing. Returns `true` if the
    /// given `executable` is on the allowlist (arguments are not
    /// currently restricted — that's a future tightening).
    static func isAllowed(executable: String, arguments: [String]) -> Bool {
        // Require an absolute path; reject `../` traversal and relative
        // paths outright. The main app always hands us absolute paths
        // (that's how the runners are defined), and an allowlist that
        // accepts relative paths is just a suggestion.
        guard executable.hasPrefix("/") else { return false }
        guard !executable.contains("..") else { return false }
        return allowedExecutables.contains(executable)
    }
}

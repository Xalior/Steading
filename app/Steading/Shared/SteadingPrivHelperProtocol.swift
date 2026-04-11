import Foundation

/// Mach service name used by both the XPC listener in the privileged
/// helper and the `NSXPCConnection` created by the main app. It's
/// advertised by the helper's embedded LaunchDaemon plist and matches
/// the helper's bundle identifier for convenience.
public let SteadingPrivHelperMachServiceName = "com.xalior.Steading.privhelper"

/// XPC contract between the main Steading app and its privileged
/// helper tool. The helper runs as root under launchd; this protocol
/// is the only way the main app can ask it to do anything.
///
/// Designed for the design-doc requirement that Steading's admin
/// surface wraps macOS built-ins (`systemsetup`, `launchctl`,
/// `socketfilterfw`, `cupsctl`, `pmset`, `AssetCacheManagerUtil`) —
/// every privileged operation we need in v1 is just running one of
/// those tools with specific arguments. The helper enforces a hard
/// allowlist of executables so the main app can't escalate beyond
/// the built-ins surface this protocol was created for.
@objc(SteadingPrivHelperProtocol)
public protocol SteadingPrivHelperProtocol {

    /// Run an allowlisted command-line tool with the given arguments
    /// as root and return `(exitCode, stdout, stderr)`.
    ///
    /// If `executable` isn't in the helper's allowlist the reply is
    /// `(-1, <empty>, "not allowlisted…")` and no subprocess runs.
    func runCommand(executable: String,
                    arguments: [String],
                    withReply reply: @escaping (Int32, Data, Data) -> Void)

    /// Version ping — the main app calls this to confirm it can
    /// reach the helper and that the helper binary embedded in the
    /// app bundle matches the registered one.
    func helperVersion(withReply reply: @escaping (String) -> Void)
}

/// Version string reported by `helperVersion(withReply:)`. Bump this
/// whenever the helper's on-the-wire protocol, allowlist, or
/// verification logic changes so the main app can detect a stale
/// registration and re-register.
public let SteadingPrivHelperVersion = "0.0.1"

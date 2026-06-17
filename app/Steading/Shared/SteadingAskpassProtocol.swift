import Foundation

/// Wire protocol for the Unix-socket IPC between the
/// `steading-askpass` CLI and the Steading GUI. Simple line-oriented
/// request/response; the helper sends a request line, the GUI sends
/// back a status line and (on success) the password line.
///
/// Grammar:
///   helper  → server: "STEADING-ASKPASS 1 fetch\n"     — normal password request
///   helper  → server: "STEADING-ASKPASS 1 validate\n"  — pre-cache validation request
///   server → helper:  "OK\n<password>\n"        — password follows, no trailing newline beyond its own
///   server → helper:  "CANCEL\n"                — user dismissed modal
///   server → helper:  "DENY\n"                  — peer validation failed; helper exits 1
///
/// The `validate` request is emitted only by the throwaway `sudo -k -v`
/// the GUI spawns to check a candidate password before caching it (the
/// helper sends it when `STEADING_ASKPASS_VALIDATION=1` is in its env).
/// The server answers a `validate` request only while it is actively in
/// that validation window; a `validate` request at any other time is an
/// anomaly — the server `DENY`s it and warns the user.
public enum SteadingAskpassWire {
    public static let version = 1
    public static let requestLine = "STEADING-ASKPASS 1 fetch"
    public static let validateRequestLine = "STEADING-ASKPASS 1 validate"
    public static let okLine     = "OK"
    public static let cancelLine = "CANCEL"
    public static let denyLine   = "DENY"

    /// Env var the GUI sets on the throwaway validation `sudo` so the
    /// bundled helper sends `validateRequestLine` instead of `requestLine`.
    public static let validationEnvVar = "STEADING_ASKPASS_VALIDATION"

    /// Per-user Unix socket path the GUI listens on and the helper
    /// connects to. 0600 perms. Lives inside the user's Application
    /// Support dir so it's never world-readable.
    public static func socketPath() -> String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask).first!
            .appendingPathComponent("Steading", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // sockaddr_un.sun_path is 104 chars on macOS — short name to
        // stay well under that limit even for deeply-nested home dirs.
        return dir.appendingPathComponent("askpass.sock").path
    }
}

/// Code-signing requirement the GUI side uses to validate incoming
/// helper peers. Mirror of the requirement the helper uses to validate
/// the GUI server. Both ends pin the other.
public let SteadingAskpassHelperRequirement =
    "identifier \"com.xalior.Steading.askpass\" and anchor apple generic and " +
    "certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */ and " +
    "certificate leaf[subject.OU] = \"M353B943AK\""

public let SteadingAskpassServerRequirement =
    "identifier \"com.xalior.Steading\" and anchor apple generic and " +
    "certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */ and " +
    "certificate leaf[subject.OU] = \"M353B943AK\""

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
/// Trust model:
///
/// 1. **Codesign pinning.** The XPC listener accepts only connections
///    from a peer whose codesign requirements match Steading's main
///    app — we own both ends, the main app is the only client.
/// 2. **YAML-derived approval.** Every privileged write/create/remove
///    method takes a `yamlHash` Data parameter naming the
///    service-definition YAML it derives from. The helper consults
///    its own approvals plist at
///    `/Library/Application Support/Steading/approvals.plist`
///    (root:wheel, 0600) and rejects writes whose `(yamlPath, hash)`
///    aren't approved.
/// 3. **Categorical refusal list.** `PrivHelperRefusalList` is a
///    third gate — even an approved YAML can't write to
///    `/etc/sudoers`, drop a rogue `/Library/PrivilegedHelperTools/`
///    binary, escape via symlink, etc.
///
/// Reply types are kept to the (Bool, String) / (Data, String) shape
/// the existing methods use because NSXPC requires NSSecureCoding-
/// friendly types — Result<Success, Error> doesn't bridge cleanly.
@objc(SteadingPrivHelperProtocol)
public protocol SteadingPrivHelperProtocol {

    // MARK: - Existing surface

    /// Run an allowlisted command-line tool with the given arguments
    /// as root and return `(exitCode, stdout, stderr)`. See
    /// `PrivHelperAllowlist` for the accepted executables.
    func runCommand(executable: String,
                    arguments: [String],
                    withReply reply: @escaping (Int32, Data, Data) -> Void)

    /// Atomically replace `/etc/hosts` with the given bytes.
    /// Purpose-built per-file method (path is pinned in the helper).
    func writeHostsFile(content: Data,
                        withReply reply: @escaping (Bool, String) -> Void)

    /// Version ping — confirms the registered helper matches the
    /// embedded one.
    func helperVersion(withReply reply: @escaping (String) -> Void)

    // MARK: - Approvals

    /// Record a YAML approval. `yamlPath` is the absolute path on
    /// disk (bundle resource path or external data dir path);
    /// `hash` is the SHA-256 hex of the file at the time of
    /// approval. Reply is `(success, errorMessage)`.
    func recordApproval(yamlPath: String,
                        hash: String,
                        withReply reply: @escaping (Bool, String) -> Void)

    /// Fetch the current approvals list. Reply is JSON-encoded
    /// `[String: String]` mapping yamlPath → hash.
    func listApprovals(withReply reply: @escaping (Data, String) -> Void)

    /// Drop a previously-recorded approval. Reply is
    /// `(success, errorMessage)`. Removing a non-existent entry is
    /// not an error.
    func forgetApproval(yamlPath: String,
                        withReply reply: @escaping (Bool, String) -> Void)

    // MARK: - File operations

    /// Atomically write `content` to `path` with the given
    /// permissions and ownership. `yamlHash` ties the call to a
    /// previously-approved YAML.
    func writeFile(path: String,
                   mode: Int,
                   ownerUID: Int,
                   groupGID: Int,
                   content: Data,
                   yamlHash: String,
                   withReply reply: @escaping (Bool, String) -> Void)

    /// Read the contents of `path`. Used by Edit Config to access
    /// files that aren't owner-readable from the user's account
    /// (e.g. `_mysql:_mysql`-owned config). Reply is
    /// `(content, errorMessage)`; on failure content is empty.
    func readFile(path: String,
                  yamlHash: String,
                  withReply reply: @escaping (Data, String) -> Void)

    /// Remove `path`. Errors if the path is a directory; use
    /// `removeDirectory` for directories.
    func removeFile(path: String,
                    yamlHash: String,
                    withReply reply: @escaping (Bool, String) -> Void)

    /// Create a directory at `path` (creating intermediate
    /// directories as needed) with the given mode and owner.
    func makeDirectory(path: String,
                       mode: Int,
                       ownerUID: Int,
                       groupGID: Int,
                       yamlHash: String,
                       withReply reply: @escaping (Bool, String) -> Void)

    /// Remove the directory at `path`. When `recursive` is true,
    /// removes the directory and its contents.
    func removeDirectory(path: String,
                         recursive: Bool,
                         yamlHash: String,
                         withReply reply: @escaping (Bool, String) -> Void)

    // MARK: - System users

    /// Create a `_<service>` system user. The helper enforces:
    ///
    /// - `name` must match `_<id>` for a known serviceID.
    /// - If the requested name already exists with a UID, the
    ///   existing UID is adopted (Apple-blessed `_mysql:74` etc.).
    /// - Otherwise the next free UID in the Steading-reserved range
    ///   410-440 is allocated.
    ///
    /// Reply carries the resolved UID so the caller can record it.
    func createSystemUser(name: String,
                          home: String,
                          yamlHash: String,
                          withReply reply: @escaping (Int, String) -> Void)

    /// Remove a `_<service>` system user.
    func removeSystemUser(name: String,
                          yamlHash: String,
                          withReply reply: @escaping (Bool, String) -> Void)

    // MARK: - LaunchDaemons

    /// Write the LaunchDaemon plist at
    /// `/Library/LaunchDaemons/<label>.plist`. Helper validates the
    /// label against `com.xalior.steading.<service>` shape; the path
    /// is derived, not parametric.
    func writeLaunchDaemon(label: String,
                           plistData: Data,
                           yamlHash: String,
                           withReply reply: @escaping (Bool, String) -> Void)

    /// `launchctl bootstrap system /Library/LaunchDaemons/<label>.plist`
    func loadLaunchDaemon(label: String,
                          withReply reply: @escaping (Bool, String) -> Void)

    /// `launchctl bootout system/<label>`
    func unloadLaunchDaemon(label: String,
                            withReply reply: @escaping (Bool, String) -> Void)

    /// `launchctl kickstart -k system/<label>`
    func bounceLaunchDaemon(label: String,
                            withReply reply: @escaping (Bool, String) -> Void)

    /// Toggle the LaunchDaemon plist's `Disabled` key.
    func setLaunchDaemonDisabled(label: String,
                                 disabled: Bool,
                                 withReply reply: @escaping (Bool, String) -> Void)

    // MARK: - Firewall

    /// Add a `socketfilterfw` rule for the LaunchDaemon. `allow=true`
    /// adds an allow-incoming rule; `allow=false` adds a block rule.
    func addFirewallRule(serviceLabel: String,
                         allow: Bool,
                         yamlHash: String,
                         withReply reply: @escaping (Bool, String) -> Void)

    /// Remove the firewall rule for the given LaunchDaemon.
    func removeFirewallRule(serviceLabel: String,
                            yamlHash: String,
                            withReply reply: @escaping (Bool, String) -> Void)

    // MARK: - Logging

    /// Append a single line to the per-service install log under
    /// `/Library/Application Support/Steading/Logs/<serviceID>-<timestamp>.log`.
    /// `timestamp` parameter scopes the log file so an
    /// install-then-uninstall produces two distinct files.
    func appendInstallLog(serviceID: String,
                          sessionTimestamp: String,
                          line: String,
                          withReply reply: @escaping (Bool, String) -> Void)
}

/// Hard cap on the size of `/etc/hosts` content the helper will
/// accept. Real-world hosts files are a few KB; 1 MiB is generous
/// while keeping a DoS ceiling on an unprivileged IPC surface.
public let SteadingHostsFileMaxSize: Int = 1 * 1024 * 1024

/// Hard cap on the size of any single helper-driven file write
/// (writeFile, writeLaunchDaemon). Per-write callers may impose
/// tighter caps via the YAML's `sizeCapBytes` (a config file gets a
/// tight cap; a log directory's data files would get a looser one),
/// but this is the floor.
public let SteadingHelperWriteMaxSize: Int = 4 * 1024 * 1024

/// Steading-reserved UID range for `_<service>` users that don't
/// have an Apple-blessed UID. See
/// `PrivHelperService.allocateServiceUID(name:)`.
public let SteadingReservedUIDRangeLow: Int = 410
public let SteadingReservedUIDRangeHigh: Int = 440

/// Approvals plist path. Read/written by the helper only;
/// `root:wheel`, mode `0600`. Main app cannot tamper directly —
/// every mutation goes through `recordApproval` / `forgetApproval`.
public let SteadingApprovalsPlistPath = "/Library/Application Support/Steading/approvals.plist"

/// Per-service install/uninstall log directory. Helper-owned.
public let SteadingInstallLogDirectory = "/Library/Application Support/Steading/Logs"

/// Version string reported by `helperVersion(withReply:)`. Bump this
/// whenever the helper's on-the-wire protocol, allowlist, or
/// verification logic changes so the main app can detect a stale
/// registration and re-register.
public let SteadingPrivHelperVersion = "0.1.0"

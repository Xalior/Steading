import Foundation
import ServiceManagement
import os.log

/// The main app's gateway to the privileged helper. Owns registration
/// with `SMAppService` and the `NSXPCConnection` used to dispatch
/// commands.
///
/// Design notes
/// ------------
/// - One long-lived `NSXPCConnection` per run of the app. launchd
///   manages the helper process's lifetime on the other side; this
///   client just pools the connection and re-creates it if it's
///   invalidated.
/// - `runCommand(_:)` takes the same argv shape as the built-in
///   service runners' `enableCommand` / `disableCommand` arrays — the
///   first element is the executable, the rest are arguments.
/// - Every failure bubbles as a `PrivHelperClient.Error` with a
///   user-shaped message; `BuiltInServiceDetailView` surfaces it
///   verbatim in its error banner.
@MainActor
final class PrivHelperClient {

    static let shared = PrivHelperClient()

    enum Error: Swift.Error, LocalizedError {
        case empty
        case registrationFailed(String)
        case requiresApproval
        case notRegistered
        case noProxy
        case xpcFailed(String)
        case helperError(code: Int32, message: String)
        case hostsFileTooLarge(Int)
        case hostsWriteFailed(String)

        var errorDescription: String? {
            switch self {
            case .empty:
                return "Empty command"
            case .registrationFailed(let msg):
                return "Could not register privileged helper: \(msg)"
            case .requiresApproval:
                return "Steading's privileged helper is awaiting your approval in System Settings → General → Login Items & Extensions."
            case .notRegistered:
                return "Privileged helper is not registered."
            case .noProxy:
                return "Could not reach the privileged helper (no remote proxy)."
            case .xpcFailed(let msg):
                return "XPC connection failed: \(msg)"
            case .helperError(let code, let message):
                return "Helper returned exit \(code): \(message)"
            case .hostsFileTooLarge(let size):
                return "Hosts file is too large (\(size) bytes; limit is \(SteadingHostsFileMaxSize))."
            case .hostsWriteFailed(let msg):
                return "Could not write /etc/hosts: \(msg)"
            }
        }
    }

    /// Embedded-LaunchDaemon-plist filename inside the app bundle's
    /// `Contents/Library/LaunchDaemons/` directory. Must match the
    /// file we drop at build time.
    private let daemonPlistName = "com.xalior.Steading.privhelper.plist"

    private let log = Logger(subsystem: "com.xalior.Steading", category: "privhelper-client")
    private var connection: NSXPCConnection?

    /// Code-signing designated requirement the helper process must
    /// satisfy before we'll send it commands. Mirror of the client
    /// requirement the helper pins on its side (PrivHelperListener-
    /// Delegate): both ends check the other against the Steading
    /// team OU and the expected bundle identifier, so nothing squatting
    /// the mach service name can impersonate the real helper.
    ///
    /// See docs/ARCHITECTURE.md — "Mutual code-sign pinning" — for the
    /// threat model this closes.
    private let helperRequirement =
        "identifier \"com.xalior.Steading.privhelper\" and anchor apple generic and " +
        "certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */ and " +
        "certificate leaf[subject.OU] = \"M353B943AK\""

    private init() {}

    // MARK: - Registration

    /// Current SMAppService registration status for the helper.
    var status: SMAppService.Status {
        SMAppService.daemon(plistName: daemonPlistName).status
    }

    /// Register the helper with SMAppService. If it's already
    /// registered this is a no-op. If it's pending approval the
    /// status stays `.requiresApproval` until the user toggles it in
    /// System Settings.
    func registerIfNeeded() throws {
        let service = SMAppService.daemon(plistName: daemonPlistName)
        switch service.status {
        case .enabled:
            return
        case .requiresApproval:
            throw Error.requiresApproval
        case .notRegistered, .notFound:
            do {
                try service.register()
            } catch {
                throw Error.registrationFailed(error.localizedDescription)
            }
            // Re-check status — registration often lands in
            // .requiresApproval the first time.
            if service.status == .requiresApproval {
                throw Error.requiresApproval
            }
        @unknown default:
            throw Error.notRegistered
        }
    }

    /// Open System Settings on the Login Items pane so the user can
    /// flip the approval switch.
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - XPC

    /// Run a command through the helper and return the captured
    /// result. Blocks until the helper replies.
    func runCommand(_ command: [String]) async throws -> ProcessRunner.Result {
        guard let first = command.first else { throw Error.empty }
        let arguments = Array(command.dropFirst())

        let conn = try connect()

        return try await withCheckedThrowingContinuation { continuation in
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: Error.xpcFailed(error.localizedDescription))
            } as? SteadingPrivHelperProtocol

            guard let proxy else {
                continuation.resume(throwing: Error.noProxy)
                return
            }

            proxy.runCommand(executable: first, arguments: arguments) { code, outData, errData in
                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""
                continuation.resume(returning: ProcessRunner.Result(
                    exitCode: code, stdout: stdout, stderr: stderr
                ))
            }
        }
    }

    /// Atomically replace `/etc/hosts` with the given content. The
    /// helper performs the write as root; callers provide the full
    /// file contents.
    func writeHostsFile(_ content: String) async throws {
        guard let data = content.data(using: .utf8) else {
            throw Error.hostsWriteFailed("Content is not valid UTF-8")
        }
        if data.count > SteadingHostsFileMaxSize {
            throw Error.hostsFileTooLarge(data.count)
        }

        let conn = try connect()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: Error.xpcFailed(error.localizedDescription))
            } as? SteadingPrivHelperProtocol

            guard let proxy else {
                continuation.resume(throwing: Error.noProxy)
                return
            }

            proxy.writeHostsFile(content: data) { success, message in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: Error.hostsWriteFailed(message))
                }
            }
        }
    }

    /// Ask the helper for its version string. Useful as a ping and
    /// for detecting a stale helper registration.
    func helperVersion() async throws -> String {
        let conn = try connect()
        return try await withCheckedThrowingContinuation { continuation in
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: Error.xpcFailed(error.localizedDescription))
            } as? SteadingPrivHelperProtocol

            guard let proxy else {
                continuation.resume(throwing: Error.noProxy)
                return
            }
            proxy.helperVersion { version in
                continuation.resume(returning: version)
            }
        }
    }

    // MARK: - Connection

    private func connect() throws -> NSXPCConnection {
        if let connection { return connection }

        // .privileged tells NSXPCConnection to look for the mach
        // service in launchd's system domain (i.e. a LaunchDaemon),
        // not a LaunchAgent.
        let conn = NSXPCConnection(
            machServiceName: SteadingPrivHelperMachServiceName,
            options: .privileged
        )
        // Refuse to talk to anything on the other end of the mach
        // service that isn't the real Steading helper. Closes the
        // symmetric gap to the helper's own client verification.
        conn.setCodeSigningRequirement(helperRequirement)
        conn.remoteObjectInterface = NSXPCInterface(with: SteadingPrivHelperProtocol.self)
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.log.info("priv helper XPC connection invalidated")
                self?.connection = nil
            }
        }
        conn.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.log.info("priv helper XPC connection interrupted")
                self?.connection = nil
            }
        }
        conn.resume()
        connection = conn
        return conn
    }
}

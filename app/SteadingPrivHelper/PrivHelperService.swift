import Foundation
import Darwin
import os.log

// When this file is compiled into the SteadingTests target (so XPC
// round-trip tests can stand up a real PrivHelperService behind an
// anonymous listener), the protocol and Shared/ types come from the
// Steading module rather than this target's own compilation. The
// helper target itself compiles Shared/ directly and does not see
// STEADING_TEST_HOST, so the import is a no-op there.
#if STEADING_TEST_HOST
@testable import Steading
#endif

/// Concrete implementation of `SteadingPrivHelperProtocol`. Runs as
/// root; this is the code that actually spawns the allowlisted tools
/// and performs the narrow set of file mutations exposed on the XPC
/// surface.
final class PrivHelperService: NSObject, SteadingPrivHelperProtocol {

    private let log = Logger(subsystem: "com.xalior.Steading.privhelper", category: "service")

    /// Hard-coded target for `writeHostsFile`. Deliberately not a
    /// parameter on the XPC method — widening this requires source
    /// changes, not just a client with the right arguments.
    private let hostsFilePath = "/etc/hosts"

    private let approvalsURL: URL

    /// Production init: persists approvals at the canonical path
    /// (`/Library/Application Support/Steading/approvals.plist`).
    override init() {
        self.approvalsURL = URL(fileURLWithPath: SteadingApprovalsPlistPath)
        super.init()
    }

    /// Test init: redirects approvals to a caller-provided URL so
    /// `XPCIntegrationTests` and friends can drive the real service
    /// against a temp directory without root or side effects in
    /// `/Library`. Production code uses the override-less init.
    init(approvalsURL: URL) {
        self.approvalsURL = approvalsURL
        super.init()
    }

    func helperVersion(withReply reply: @escaping (String) -> Void) {
        reply(SteadingPrivHelperVersion)
    }

    func runCommand(executable: String,
                    arguments: [String],
                    withReply reply: @escaping (Int32, Data, Data) -> Void) {
        guard PrivHelperAllowlist.isAllowed(executable: executable, arguments: arguments) else {
            log.error("rejected disallowed command: \(executable) \(arguments.joined(separator: " "))")
            let message = "privhelper: command not in allowlist: \(executable)"
            reply(-1, Data(), message.data(using: .utf8) ?? Data())
            return
        }
        log.info("running \(executable) \(arguments.joined(separator: " "))")
        let result = spawn(executable: executable, arguments: arguments)
        reply(result.exitCode, result.stdout, result.stderr)
    }

    func writeHostsFile(content: Data,
                        withReply reply: @escaping (Bool, String) -> Void) {
        if content.count > SteadingHostsFileMaxSize {
            let message = "hosts payload exceeds \(SteadingHostsFileMaxSize) bytes (\(content.count))"
            log.error("writeHostsFile rejected: \(message, privacy: .public)")
            reply(false, message)
            return
        }
        switch HostsFileWriter.write(content: content, to: hostsFilePath) {
        case .success:
            log.info("writeHostsFile: wrote \(content.count) bytes to \(self.hostsFilePath, privacy: .public)")
            reply(true, "")
        case .failure(let message):
            log.error("writeHostsFile failed: \(message, privacy: .public)")
            reply(false, message)
        }
    }

    // MARK: - Approvals

    func recordApproval(yamlPath: String,
                        hash: String,
                        withReply reply: @escaping (Bool, String) -> Void) {
        do {
            var entries = try ApprovalsStore.read(from: approvalsURL)
            ApprovalsStore.record(&entries, yamlPath: yamlPath, hash: hash)
            try ApprovalsStore.write(entries, to: approvalsURL)
            log.info("recordApproval: \(yamlPath, privacy: .public)")
            reply(true, "")
        } catch {
            log.error("recordApproval failed: \(error.localizedDescription, privacy: .public)")
            reply(false, error.localizedDescription)
        }
    }

    func listApprovals(withReply reply: @escaping (Data, String) -> Void) {
        do {
            let entries = try ApprovalsStore.read(from: approvalsURL)
            let data = try JSONEncoder().encode(entries)
            reply(data, "")
        } catch {
            reply(Data(), error.localizedDescription)
        }
    }

    func forgetApproval(yamlPath: String,
                        withReply reply: @escaping (Bool, String) -> Void) {
        do {
            var entries = try ApprovalsStore.read(from: approvalsURL)
            ApprovalsStore.forget(&entries, yamlPath: yamlPath)
            try ApprovalsStore.write(entries, to: approvalsURL)
            log.info("forgetApproval: \(yamlPath, privacy: .public)")
            reply(true, "")
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    // MARK: - File operations

    func writeFile(path: String,
                   mode: Int,
                   ownerUID: Int,
                   groupGID: Int,
                   content: Data,
                   yamlHash: String,
                   withReply reply: @escaping (Bool, String) -> Void) {
        if let reason = approvalRejection(yamlHash: yamlHash) {
            log.error("writeFile approval rejected: \(reason, privacy: .public)")
            reply(false, reason); return
        }
        if let reason = PrivHelperRefusalList.refuse(path: path, mode: mode) {
            log.error("writeFile refused for \(path, privacy: .public): \(reason.description, privacy: .public)")
            reply(false, reason.description); return
        }
        if content.count > SteadingHelperWriteMaxSize {
            reply(false, "content exceeds \(SteadingHelperWriteMaxSize) bytes"); return
        }
        switch PrivilegedFileWriter.write(content: content, to: path,
                                          mode: mode_t(mode),
                                          ownerUID: ownerUID, groupGID: groupGID) {
        case .success:
            log.info("writeFile: \(content.count) bytes -> \(path, privacy: .public)")
            reply(true, "")
        case .failure(let msg):
            log.error("writeFile failed: \(msg, privacy: .public)")
            reply(false, msg)
        }
    }

    func readFile(path: String,
                  yamlHash: String,
                  withReply reply: @escaping (Data, String) -> Void) {
        if let reason = approvalRejection(yamlHash: yamlHash) {
            reply(Data(), reason); return
        }
        if let reason = PrivHelperRefusalList.refuse(path: path, mode: 0o600) {
            reply(Data(), reason.description); return
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            reply(data, "")
        } catch {
            reply(Data(), error.localizedDescription)
        }
    }

    func removeFile(path: String,
                    yamlHash: String,
                    withReply reply: @escaping (Bool, String) -> Void) {
        if let reason = approvalRejection(yamlHash: yamlHash) {
            reply(false, reason); return
        }
        if let reason = PrivHelperRefusalList.refuse(path: path, mode: 0o600) {
            reply(false, reason.description); return
        }
        var statBuf = stat()
        if lstat(path, &statBuf) != 0 {
            // Already gone is OK for idempotent reverse-teardown.
            if errno == ENOENT { reply(true, ""); return }
            reply(false, String(cString: strerror(errno))); return
        }
        if (statBuf.st_mode & S_IFMT) == S_IFDIR {
            reply(false, "path is a directory; use removeDirectory"); return
        }
        if unlink(path) != 0 {
            reply(false, String(cString: strerror(errno))); return
        }
        log.info("removeFile: \(path, privacy: .public)")
        reply(true, "")
    }

    func makeDirectory(path: String,
                       mode: Int,
                       ownerUID: Int,
                       groupGID: Int,
                       yamlHash: String,
                       withReply reply: @escaping (Bool, String) -> Void) {
        if let reason = approvalRejection(yamlHash: yamlHash) {
            reply(false, reason); return
        }
        if let reason = PrivHelperRefusalList.refuse(path: path, mode: mode) {
            reply(false, reason.description); return
        }
        switch PrivilegedFileWriter.makeDirectory(at: path,
                                                  mode: mode_t(mode),
                                                  ownerUID: ownerUID,
                                                  groupGID: groupGID) {
        case .success:
            log.info("makeDirectory: \(path, privacy: .public)")
            reply(true, "")
        case .failure(let msg):
            reply(false, msg)
        }
    }

    func removeDirectory(path: String,
                         recursive: Bool,
                         yamlHash: String,
                         withReply reply: @escaping (Bool, String) -> Void) {
        if let reason = approvalRejection(yamlHash: yamlHash) {
            reply(false, reason); return
        }
        if let reason = PrivHelperRefusalList.refuse(path: path, mode: 0o755) {
            reply(false, reason.description); return
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            reply(true, ""); return
        }
        do {
            if recursive {
                try fm.removeItem(atPath: path)
            } else {
                if rmdir(path) != 0 {
                    reply(false, String(cString: strerror(errno))); return
                }
            }
            log.info("removeDirectory: \(path, privacy: .public) recursive=\(recursive)")
            reply(true, "")
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    // MARK: - System users

    func createSystemUser(name: String,
                          home: String,
                          yamlHash: String,
                          withReply reply: @escaping (Int, String) -> Void) {
        if let reason = approvalRejection(yamlHash: yamlHash) {
            reply(-1, reason); return
        }
        guard name.hasPrefix("_"), name.count > 1, name.count <= 32 else {
            reply(-1, "name must match _<service>"); return
        }
        // Adopt existing UID if the user already exists (Apple-blessed
        // _mysql:74 etc.). Otherwise allocate the next free UID in
        // Steading's reserved range 410-440.
        if let existing = lookupUID(name: name) {
            log.info("createSystemUser: adopting existing \(name, privacy: .public) uid=\(existing)")
            reply(existing, ""); return
        }
        guard let uid = allocateServiceUID() else {
            reply(-1, "no free UID in \(SteadingReservedUIDRangeLow)…\(SteadingReservedUIDRangeHigh)"); return
        }
        // dscl . -create /Users/<name> ; -create UniqueID; PrimaryGroupID; UserShell; NFSHomeDirectory; RealName
        let dscl = "/usr/bin/dscl"
        let path = "/Users/\(name)"
        let steps: [[String]] = [
            [".", "-create", path],
            [".", "-create", path, "UniqueID", "\(uid)"],
            [".", "-create", path, "PrimaryGroupID", "\(uid)"],
            [".", "-create", path, "UserShell", "/usr/bin/false"],
            [".", "-create", path, "NFSHomeDirectory", home],
            [".", "-create", path, "RealName", "Steading service \(name)"],
            [".", "-create", path, "Password", "*"],
        ]
        for args in steps {
            let r = spawn(executable: dscl, arguments: args)
            if r.exitCode != 0 {
                reply(-1, "dscl \(args.joined(separator: " ")) exited \(r.exitCode): \(String(data: r.stderr, encoding: .utf8) ?? "")")
                return
            }
        }
        log.info("createSystemUser: created \(name, privacy: .public) uid=\(uid)")
        reply(uid, "")
    }

    func removeSystemUser(name: String,
                          yamlHash: String,
                          withReply reply: @escaping (Bool, String) -> Void) {
        if let reason = approvalRejection(yamlHash: yamlHash) {
            reply(false, reason); return
        }
        guard name.hasPrefix("_"), name.count > 1 else {
            reply(false, "name must match _<service>"); return
        }
        let r = spawn(executable: "/usr/bin/dscl", arguments: [".", "-delete", "/Users/\(name)"])
        if r.exitCode != 0 {
            reply(false, "dscl exited \(r.exitCode): \(String(data: r.stderr, encoding: .utf8) ?? "")")
            return
        }
        log.info("removeSystemUser: removed \(name, privacy: .public)")
        reply(true, "")
    }

    private func lookupUID(name: String) -> Int? {
        let r = spawn(executable: "/usr/bin/dscl", arguments: [".", "-read", "/Users/\(name)", "UniqueID"])
        guard r.exitCode == 0 else { return nil }
        let out = String(data: r.stdout, encoding: .utf8) ?? ""
        // Expected: "UniqueID: 74\n"
        let parts = out.split(separator: ":")
        guard parts.count == 2 else { return nil }
        return Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func allocateServiceUID() -> Int? {
        let used = inUseUIDs(in: SteadingReservedUIDRangeLow...SteadingReservedUIDRangeHigh)
        for uid in SteadingReservedUIDRangeLow...SteadingReservedUIDRangeHigh {
            if !used.contains(uid) { return uid }
        }
        return nil
    }

    private func inUseUIDs(in range: ClosedRange<Int>) -> Set<Int> {
        let r = spawn(executable: "/usr/bin/dscl", arguments: [".", "-list", "/Users", "UniqueID"])
        guard r.exitCode == 0, let out = String(data: r.stdout, encoding: .utf8) else { return [] }
        var used = Set<Int>()
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if let last = parts.last, let uid = Int(last), range.contains(uid) {
                used.insert(uid)
            }
        }
        return used
    }

    // MARK: - LaunchDaemons

    func writeLaunchDaemon(label: String,
                           plistData: Data,
                           yamlHash: String,
                           withReply reply: @escaping (Bool, String) -> Void) {
        if let reason = approvalRejection(yamlHash: yamlHash) {
            reply(false, reason); return
        }
        guard label.hasPrefix("com.xalior.steading."), !label.contains("/") else {
            reply(false, "label must start with com.xalior.steading. and contain no path separators"); return
        }
        let path = "/Library/LaunchDaemons/\(label).plist"
        if let reason = PrivHelperRefusalList.refuse(path: path, mode: 0o644) {
            reply(false, reason.description); return
        }
        if plistData.count > SteadingHelperWriteMaxSize {
            reply(false, "plist exceeds \(SteadingHelperWriteMaxSize) bytes"); return
        }
        // Sanity check: plist must round-trip through PropertyListSerialization.
        do {
            _ = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)
        } catch {
            reply(false, "plist parse: \(error.localizedDescription)"); return
        }
        switch PrivilegedFileWriter.write(content: plistData, to: path,
                                          mode: 0o644, ownerUID: 0, groupGID: 0) {
        case .success:
            log.info("writeLaunchDaemon: \(label, privacy: .public)")
            reply(true, "")
        case .failure(let msg):
            reply(false, msg)
        }
    }

    func loadLaunchDaemon(label: String,
                          withReply reply: @escaping (Bool, String) -> Void) {
        let path = "/Library/LaunchDaemons/\(label).plist"
        let r = spawn(executable: "/bin/launchctl", arguments: ["bootstrap", "system", path])
        if r.exitCode != 0 {
            reply(false, "launchctl bootstrap: exit \(r.exitCode): \(String(data: r.stderr, encoding: .utf8) ?? "")")
            return
        }
        reply(true, "")
    }

    func unloadLaunchDaemon(label: String,
                            withReply reply: @escaping (Bool, String) -> Void) {
        let r = spawn(executable: "/bin/launchctl", arguments: ["bootout", "system/\(label)"])
        // bootout can return non-zero when the service is already gone;
        // surface stderr but don't treat as fatal.
        if r.exitCode != 0 {
            let stderr = String(data: r.stderr, encoding: .utf8) ?? ""
            reply(false, "launchctl bootout: exit \(r.exitCode): \(stderr)"); return
        }
        reply(true, "")
    }

    func bounceLaunchDaemon(label: String,
                            withReply reply: @escaping (Bool, String) -> Void) {
        let r = spawn(executable: "/bin/launchctl", arguments: ["kickstart", "-k", "system/\(label)"])
        if r.exitCode != 0 {
            reply(false, "launchctl kickstart: exit \(r.exitCode)"); return
        }
        reply(true, "")
    }

    func setLaunchDaemonDisabled(label: String,
                                 disabled: Bool,
                                 withReply reply: @escaping (Bool, String) -> Void) {
        let path = "/Library/LaunchDaemons/\(label).plist"
        guard FileManager.default.fileExists(atPath: path) else {
            reply(false, "no plist at \(path)"); return
        }
        // Mutate the plist's Disabled key in place.
        let url = URL(fileURLWithPath: path)
        do {
            let data = try Data(contentsOf: url)
            var format: PropertyListSerialization.PropertyListFormat = .xml
            guard var root = try PropertyListSerialization.propertyList(
                from: data, options: [], format: &format
            ) as? [String: Any] else {
                reply(false, "plist root is not a dictionary"); return
            }
            root["Disabled"] = disabled
            let updated = try PropertyListSerialization.data(
                fromPropertyList: root, format: format, options: 0
            )
            switch PrivilegedFileWriter.write(content: updated, to: path,
                                              mode: 0o644, ownerUID: 0, groupGID: 0) {
            case .success:
                reply(true, "")
            case .failure(let m):
                reply(false, m)
            }
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    // MARK: - Firewall

    func addFirewallRule(serviceLabel: String,
                         allow: Bool,
                         yamlHash: String,
                         withReply reply: @escaping (Bool, String) -> Void) {
        if let reason = approvalRejection(yamlHash: yamlHash) {
            reply(false, reason); return
        }
        let appPath = "/Library/LaunchDaemons/\(serviceLabel).plist"
        let action = allow ? "--add" : "--add"
        let r = spawn(executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
                      arguments: [action, appPath])
        if r.exitCode != 0 {
            reply(false, "socketfilterfw exit \(r.exitCode): \(String(data: r.stderr, encoding: .utf8) ?? "")")
            return
        }
        // socketfilterfw doesn't have a dedicated block flag for
        // first-party apps; "allow" is the default once added. For
        // explicit block, follow with --blockapp.
        if !allow {
            let r2 = spawn(executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
                           arguments: ["--blockapp", appPath])
            if r2.exitCode != 0 {
                reply(false, "socketfilterfw --blockapp exit \(r2.exitCode)"); return
            }
        }
        reply(true, "")
    }

    func removeFirewallRule(serviceLabel: String,
                            yamlHash: String,
                            withReply reply: @escaping (Bool, String) -> Void) {
        if let reason = approvalRejection(yamlHash: yamlHash) {
            reply(false, reason); return
        }
        let appPath = "/Library/LaunchDaemons/\(serviceLabel).plist"
        let r = spawn(executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
                      arguments: ["--remove", appPath])
        if r.exitCode != 0 {
            reply(false, "socketfilterfw --remove exit \(r.exitCode)"); return
        }
        reply(true, "")
    }

    // MARK: - Logging

    func appendInstallLog(serviceID: String,
                          sessionTimestamp: String,
                          line: String,
                          withReply reply: @escaping (Bool, String) -> Void) {
        // Sanity-check inputs to avoid filename injection.
        let safeID = serviceID.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        let safeTs = sessionTimestamp.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard safeID, safeTs, !serviceID.isEmpty, !sessionTimestamp.isEmpty else {
            reply(false, "invalid serviceID or sessionTimestamp"); return
        }
        let dir = SteadingInstallLogDirectory
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: dir),
                withIntermediateDirectories: true
            )
        } catch {
            reply(false, "createDirectory: \(error.localizedDescription)"); return
        }
        let path = "\(dir)/\(serviceID)-\(sessionTimestamp).log"
        let payload = (line.hasSuffix("\n") ? line : line + "\n")
        guard let data = payload.data(using: .utf8) else {
            reply(false, "non-utf8 log line"); return
        }
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else {
            reply(false, "open \(path): \(String(cString: strerror(errno)))"); return
        }
        defer { close(fd) }
        if geteuid() == 0 { _ = fchown(fd, 0, 0) }
        let written = data.withUnsafeBytes { buf -> Int in
            guard let base = buf.baseAddress else { return 0 }
            return Darwin.write(fd, base, data.count)
        }
        if written < 0 {
            reply(false, "write: \(String(cString: strerror(errno)))"); return
        }
        reply(true, "")
    }

    // MARK: - Internal helpers

    /// Returns a rejection message when `yamlHash` doesn't match any
    /// recorded approval, or nil when the call may proceed.
    private func approvalRejection(yamlHash: String) -> String? {
        do {
            let entries = try ApprovalsStore.read(from: approvalsURL)
            if ApprovalsStore.anyApproval(entries, matchesHash: yamlHash) {
                return nil
            }
            return "no approval recorded for yamlHash \(yamlHash)"
        } catch {
            return "approvals read failed: \(error.localizedDescription)"
        }
    }

    private struct SpawnResult { let exitCode: Int32; let stdout: Data; let stderr: Data }

    private func spawn(executable: String, arguments: [String]) -> SpawnResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            let msg = "failed to launch \(executable): \(error.localizedDescription)"
            return SpawnResult(exitCode: -1,
                               stdout: Data(),
                               stderr: msg.data(using: .utf8) ?? Data())
        }
        process.waitUntilExit()
        let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
        return SpawnResult(exitCode: process.terminationStatus, stdout: outData, stderr: errData)
    }
}

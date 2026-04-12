import Foundation
import Darwin
import os.log

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

    func helperVersion(withReply reply: @escaping (String) -> Void) {
        reply(SteadingPrivHelperVersion)
    }

    func runCommand(executable: String,
                    arguments: [String],
                    withReply reply: @escaping (Int32, Data, Data) -> Void) {
        // Enforce the allowlist first. This is the entire reason the
        // helper exists — the main app can ONLY ask for commands we
        // already know are safe to run as root.
        guard PrivHelperAllowlist.isAllowed(executable: executable, arguments: arguments) else {
            log.error("rejected disallowed command: \(executable) \(arguments.joined(separator: " "))")
            let message = "privhelper: command not in allowlist: \(executable)"
            reply(-1, Data(), message.data(using: .utf8) ?? Data())
            return
        }

        log.info("running \(executable) \(arguments.joined(separator: " "))")

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
            let message = "privhelper: failed to launch \(executable): \(error)"
            log.error("\(message)")
            reply(-1, Data(), message.data(using: .utf8) ?? Data())
            return
        }
        process.waitUntilExit()

        let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
        reply(process.terminationStatus, outData, errData)
    }

    // MARK: - File mutation

    func writeHostsFile(content: Data,
                        withReply reply: @escaping (Bool, String) -> Void) {
        if content.count > SteadingHostsFileMaxSize {
            let message = "hosts payload exceeds \(SteadingHostsFileMaxSize) bytes (\(content.count))"
            log.error("writeHostsFile rejected: \(message, privacy: .public)")
            reply(false, message)
            return
        }

        let result = PrivHelperService.atomicallyWriteRootOwned(
            content: content,
            to: hostsFilePath
        )
        switch result {
        case .success:
            log.info("writeHostsFile: wrote \(content.count) bytes to \(self.hostsFilePath, privacy: .public)")
            reply(true, "")
        case .failure(let message):
            log.error("writeHostsFile failed: \(message, privacy: .public)")
            reply(false, message)
        }
    }

    /// Write `content` atomically to `path` as `root:wheel 0644`.
    ///
    /// Strategy: create a sibling temp file, `fchmod` + `fchown` it to
    /// the desired mode/ownership explicitly (so the rename result
    /// doesn't depend on the helper's umask), write all bytes with a
    /// short-write retry loop, `fsync` the fd, close, then `rename(2)`
    /// into place. On any failure the temp file is unlinked and a
    /// short human-readable reason is returned.
    ///
    /// `internal` rather than `private` so unit tests can round-trip
    /// against a temp path without needing root.
    static func atomicallyWriteRootOwned(content: Data, to path: String) -> WriteResult {
        let dir = (path as NSString).deletingLastPathComponent
        let base = (path as NSString).lastPathComponent
        let tempPath = "\(dir)/.\(base).steading-new.\(getpid())"

        let fd = open(tempPath, O_WRONLY | O_CREAT | O_TRUNC | O_EXCL, 0o600)
        if fd < 0 {
            return .failure("open temp \(tempPath): \(String(cString: strerror(errno)))")
        }
        var closedAlready = false
        func closeFD() {
            if !closedAlready { close(fd); closedAlready = true }
        }
        func abort(_ reason: String) -> WriteResult {
            closeFD()
            unlink(tempPath)
            return .failure(reason)
        }

        if fchmod(fd, 0o644) != 0 {
            return abort("fchmod: \(String(cString: strerror(errno)))")
        }
        // Only chown when we have the privilege. The helper always
        // runs as root in production; the escape hatch keeps the
        // function usable in unit tests that exercise the write path
        // from a normal user.
        if geteuid() == 0 {
            if fchown(fd, 0, 0) != 0 {
                return abort("fchown: \(String(cString: strerror(errno)))")
            }
        }

        var bytesRemaining = content.count
        var offset = 0
        while bytesRemaining > 0 {
            let written = content.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int in
                guard let base = buf.baseAddress else { return 0 }
                return write(fd, base.advanced(by: offset), bytesRemaining)
            }
            if written < 0 {
                if errno == EINTR { continue }
                return abort("write: \(String(cString: strerror(errno)))")
            }
            if written == 0 {
                return abort("write: zero-byte short write")
            }
            offset += written
            bytesRemaining -= written
        }

        if fsync(fd) != 0 {
            return abort("fsync: \(String(cString: strerror(errno)))")
        }
        closeFD()

        if rename(tempPath, path) != 0 {
            let err = String(cString: strerror(errno))
            unlink(tempPath)
            return .failure("rename \(tempPath) -> \(path): \(err)")
        }
        return .success
    }

    enum WriteResult: Equatable {
        case success
        case failure(String)
    }
}

import Foundation
import Darwin

/// Atomic, permission-explicit write path used by the privileged
/// helper's `writeHostsFile` XPC method.
///
/// Lives in `Shared/` (compiled into both the main app and the
/// helper) specifically so unit tests can exercise the real write
/// logic against a temp path — no mocks, no parallel reimplementation.
/// The escape hatch for `fchown` (only attempted when effective uid
/// is 0) is what lets the tests run as a normal user without
/// reimplementing the production path.
///
/// Callers:
/// - production:  `PrivHelperService.writeHostsFile` → `write(content:to:)`
///   with path hard-coded to `/etc/hosts`
/// - tests: `HostsFileWriterTests` → `write(content:to:)` with
///   `NSTemporaryDirectory()`-relative paths
public enum HostsFileWriter {

    public enum Result: Equatable {
        case success
        case failure(String)
    }

    /// Write `content` to `path` atomically, ending at mode `0644`.
    /// When running as root (`geteuid() == 0`), also `fchown`s to
    /// `root:wheel` before the rename; outside root the ownership
    /// of the temp file is whatever the current user is.
    ///
    /// Strategy: create a sibling temp file in the same directory as
    /// `path` so the final `rename(2)` is guaranteed to stay on the
    /// same filesystem (atomic on POSIX). Explicit `fchmod` / `fchown`
    /// on the open fd so the rename result is deterministic regardless
    /// of umask.
    public static func write(content: Data, to path: String) -> Result {
        let dir = (path as NSString).deletingLastPathComponent
        let base = (path as NSString).lastPathComponent
        let tempPath = "\(dir)/.\(base).steading-new.\(getpid())"

        let fd = open(tempPath, O_WRONLY | O_CREAT | O_TRUNC | O_EXCL, 0o600)
        if fd < 0 {
            return .failure("open temp \(tempPath): \(String(cString: strerror(errno)))")
        }
        var closed = false
        func closeFD() { if !closed { close(fd); closed = true } }
        func abort(_ reason: String) -> Result {
            closeFD()
            unlink(tempPath)
            return .failure(reason)
        }

        if fchmod(fd, 0o644) != 0 {
            return abort("fchmod: \(String(cString: strerror(errno)))")
        }
        if geteuid() == 0 {
            if fchown(fd, 0, 0) != 0 {
                return abort("fchown: \(String(cString: strerror(errno)))")
            }
        }

        var remaining = content.count
        var offset = 0
        while remaining > 0 {
            let written = content.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int in
                guard let base = buf.baseAddress else { return 0 }
                return Darwin.write(fd, base.advanced(by: offset), remaining)
            }
            if written < 0 {
                if errno == EINTR { continue }
                return abort("write: \(String(cString: strerror(errno)))")
            }
            if written == 0 {
                return abort("write: zero-byte short write")
            }
            offset += written
            remaining -= written
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
}

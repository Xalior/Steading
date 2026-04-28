import Foundation
import Darwin

/// Atomic file write with explicit mode and ownership. Generalized
/// from `HostsFileWriter` for the helper's `writeFile` /
/// `writeLaunchDaemon` XPC methods, which need configurable mode and
/// owner per the YAML's WriteTarget definition.
///
/// Lives in `Shared/` so unit tests in the test target can exercise
/// the real write path against a temp directory; `fchown` is gated
/// on `geteuid() == 0` so non-root tests run cleanly.
public enum PrivilegedFileWriter {

    public enum Result: Equatable {
        case success
        case failure(String)
    }

    /// Atomically write `content` to `path` ending at `mode`. When
    /// running as root, `fchown`s to `(ownerUID, groupGID)` before
    /// the final rename. Strategy mirrors `HostsFileWriter`: sibling
    /// temp file in the same directory, explicit `fchmod`/`fchown`
    /// on the open fd so the rename result is deterministic
    /// regardless of umask, then `rename(2)` for the atomic swap.
    public static func write(content: Data,
                             to path: String,
                             mode: mode_t,
                             ownerUID: Int,
                             groupGID: Int) -> Result {
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

        if fchmod(fd, mode) != 0 {
            return abort("fchmod: \(String(cString: strerror(errno)))")
        }
        if geteuid() == 0 {
            if fchown(fd, uid_t(ownerUID), gid_t(groupGID)) != 0 {
                return abort("fchown(\(ownerUID), \(groupGID)): \(String(cString: strerror(errno)))")
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

    /// Create directory at `path` (and any missing intermediate
    /// directories) with the given mode and owner.
    public static func makeDirectory(at path: String,
                                     mode: mode_t,
                                     ownerUID: Int,
                                     groupGID: Int) -> Result {
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            return .failure("createDirectory: \(error.localizedDescription)")
        }
        // FileManager.createDirectory uses umask; reset mode + owner
        // explicitly on the leaf directory.
        if chmod(path, mode) != 0 {
            return .failure("chmod: \(String(cString: strerror(errno)))")
        }
        if geteuid() == 0 {
            if chown(path, uid_t(ownerUID), gid_t(groupGID)) != 0 {
                return .failure("chown: \(String(cString: strerror(errno)))")
            }
        }
        return .success
    }
}

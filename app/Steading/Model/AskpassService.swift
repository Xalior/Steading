import Foundation
import Observation
import Darwin
import Security

/// Unix-socket listener that answers password requests from the
/// bundled `steading-askpass` CLI. The service binds a socket inside
/// the user's Application Support dir (0600 perms) at app launch;
/// the helper connects when sudo invokes it.
///
/// Each incoming connection is validated twice: the peer's effective
/// UID must equal ours (defence in depth against another local user),
/// and its code signature must satisfy the askpass helper's pinning
/// requirement. Either failure makes the service send `DENY` and
/// drop the connection without ever presenting a modal.
///
/// On success the service publishes `pendingRequest` so the Brew
/// Package Manager view can surface the password modal. The view
/// calls `respond(password:)` or `respondCancel()` to complete the
/// exchange and release the helper.
@Observable
@MainActor
final class AskpassService {

    struct PendingRequest: Identifiable, Equatable {
        let id: UUID
    }

    private(set) var pendingRequest: PendingRequest?

    func respond(password: String?) {
        let ch = pendingChannel
        pendingChannel = nil
        pendingRequest = nil
        guard let ch else { return }
        if let password {
            ch.sendPassword(password)
        } else {
            ch.sendCancel()
        }
        ch.close()
    }

    func respondCancel() { respond(password: nil) }

    func start() {
        guard listeningFD == -1 else { return }
        let path = SteadingAskpassWire.socketPath()
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("AskpassService: socket() failed: \(String(cString: strerror(errno)))")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            NSLog("AskpassService: socket path too long")
            close(fd)
            return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            ptr.baseAddress!.copyMemory(from: pathBytes, byteCount: pathBytes.count)
        }
        let len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_len = len

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            NSLog("AskpassService: bind() failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }
        chmod(path, 0o600)

        guard listen(fd, 5) == 0 else {
            NSLog("AskpassService: listen() failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        listeningFD = fd
        // Accept runs on a background queue so a main-actor consumer
        // (test, synchronous SwiftUI binding, etc.) can't starve the
        // listener. The event handler captures `fd` directly — no
        // touching self while on the background queue — and only hops
        // back to the main actor once a validated request is ready.
        let src = DispatchSource.makeReadSource(
            fileDescriptor: fd,
            queue: DispatchQueue(label: "com.xalior.Steading.askpass.accept",
                                 qos: .userInitiated)
        )
        src.setEventHandler { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }

            if !Self.validate(peerFD: client) {
                Self.sendLine(fd: client, SteadingAskpassWire.denyLine)
                Darwin.close(client)
                return
            }

            Self.readLine(fd: client) { line in
                Task { @MainActor in
                    self?.handleRequest(fd: client, line: line)
                }
            }
        }
        src.resume()
        acceptSource = src
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listeningFD >= 0 {
            close(listeningFD)
            listeningFD = -1
        }
        unlink(SteadingAskpassWire.socketPath())
    }

    // MARK: - Internals

    private var listeningFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var pendingChannel: Channel?

    private func handleRequest(fd: Int32, line: String?) {
        guard line == SteadingAskpassWire.requestLine else {
            Self.sendLine(fd: fd, SteadingAskpassWire.denyLine)
            close(fd)
            return
        }
        if let stale = pendingChannel {
            stale.sendCancel()
            stale.close()
        }
        let channel = Channel(fd: fd)
        pendingChannel = channel
        pendingRequest = PendingRequest(id: UUID())
    }

    // MARK: - Peer validation

    private static func validate(peerFD fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return false }
        guard uid == getuid() else { return false }

        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        let rc = withUnsafeMutablePointer(to: &token) { ptr -> Int32 in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(size)) { _ in
                getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, ptr, &size)
            }
        }
        guard rc == 0 else { return false }

        let tokenData = withUnsafeBytes(of: token) { Data($0) }
        let attrs: [CFString: Any] = [kSecGuestAttributeAudit: tokenData]
        var secCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs as CFDictionary, [], &secCode) == errSecSuccess,
              let secCode else { return false }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(SteadingAskpassHelperRequirement as CFString,
                                             [], &req) == errSecSuccess, let req else {
            return false
        }
        return SecCodeCheckValidity(secCode, [], req) == errSecSuccess
    }

    // MARK: - Socket I/O helpers

    nonisolated static func sendLine(fd: Int32, _ line: String) {
        let payload = line + "\n"
        payload.withCString { p in
            _ = write(fd, p, strlen(p))
        }
    }

    /// Read one line (LF-terminated) off `fd` in the background; call
    /// `completion` on the main actor with the line (or nil on EOF /
    /// error). Simple implementation: DispatchSource on the fd.
    private static func readLine(fd: Int32, completion: @escaping (String?) -> Void) {
        let queue = DispatchQueue.global(qos: .userInitiated)
        queue.async {
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 256)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n <= 0 {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                buffer.append(contentsOf: chunk[0..<Int(n)])
                if let idx = buffer.firstIndex(of: 0x0A) {
                    let line = String(data: buffer[..<idx], encoding: .utf8)
                    DispatchQueue.main.async { completion(line) }
                    return
                }
                if buffer.count > 4096 {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
            }
        }
    }

    // MARK: - Channel

    final class Channel: @unchecked Sendable {
        private let fd: Int32
        private var closed = false
        private let lock = NSLock()

        init(fd: Int32) { self.fd = fd }

        func sendPassword(_ password: String) {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return }
            AskpassService.sendLine(fd: fd, SteadingAskpassWire.okLine)
            let payload = password + "\n"
            payload.withCString { p in
                _ = write(fd, p, strlen(p))
            }
        }

        func sendCancel() {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return }
            AskpassService.sendLine(fd: fd, SteadingAskpassWire.cancelLine)
        }

        func close() {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return }
            closed = true
            Darwin.close(fd)
        }
    }
}

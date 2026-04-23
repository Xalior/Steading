import Testing
import Foundation
import Darwin
@testable import Steading

/// Security-first coverage for the askpass Unix-socket surface.
///
/// The test host (the Steading.app binary running xctest) has
/// identifier `com.xalior.Steading`, not `com.xalior.Steading.askpass`
/// — so when it connects to its own service's socket, the
/// listener's codesign pin must reject the connection and the
/// modal must never appear.
@Suite("AskpassService — security")
@MainActor
struct AskpassServiceTests {

    @Test("insecure peer (test host, wrong bundle id) is rejected with DENY")
    func insecure_peer_rejected() async throws {
        let service = AskpassService()
        service.start()
        defer { service.stop() }

        // Give the listener a beat to bind.
        try? await Task.sleep(for: .milliseconds(50))

        let fd = try Self.connectToService()
        defer { close(fd) }

        // Send the request line.
        let request = SteadingAskpassWire.requestLine + "\n"
        request.withCString { p in _ = write(fd, p, strlen(p)) }

        // Read the response line (DENY is the expected answer).
        let response = Self.readLine(fd: fd, timeout: 2)

        #expect(response == SteadingAskpassWire.denyLine,
                "expected DENY from listener; got \(String(describing: response))")
        #expect(service.pendingRequest == nil,
                "listener must not have queued a password request from the rejected peer")
    }

    @Test("respondCancel on an idle service is a no-op")
    func respond_cancel_idle_noop() {
        let service = AskpassService()
        #expect(service.pendingRequest == nil)
        service.respondCancel()
        #expect(service.pendingRequest == nil)
    }

    // MARK: - Helpers

    private static func connectToService() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketError.socketFailed(String(cString: strerror(errno)))
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = SteadingAskpassWire.socketPath()
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            ptr.baseAddress!.copyMemory(from: bytes, byteCount: bytes.count)
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw SocketError.connectFailed(reason)
        }
        return fd
    }

    private static func readLine(fd: Int32, timeout: TimeInterval) -> String? {
        var to = timeval(tv_sec: __darwin_time_t(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &to, socklen_t(MemoryLayout<timeval>.size))

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 128)
        while buffer.count < 4096 {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<Int(n)])
            if let idx = buffer.firstIndex(of: 0x0A) {
                return String(data: buffer[..<idx], encoding: .utf8)
            }
        }
        return buffer.isEmpty ? nil : String(data: buffer, encoding: .utf8)
    }

    enum SocketError: Error {
        case socketFailed(String)
        case connectFailed(String)
    }
}

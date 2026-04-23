import Foundation
import Darwin
import Security

/// `steading-askpass` — the `SUDO_ASKPASS` target bundled inside
/// Steading.app. When sudo invokes this binary, it connects to the
/// running Steading GUI over a Unix-domain socket, asks for the
/// password, prints it to stdout, and exits.
///
/// Any failure path (no socket, peer validation fails, GUI cancels,
/// timeout) exits non-zero with no output — sudo treats that as an
/// auth failure.

let kReplyTimeout: timeval = timeval(tv_sec: 120, tv_usec: 0)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("steading-askpass: \(message)\n".utf8))
    exit(1)
}

// MARK: - Connect

let socketPath = SteadingAskpassWire.socketPath()
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
if fd < 0 { fail("socket(): \(String(cString: strerror(errno)))") }

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(socketPath.utf8)
guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
    fail("socket path too long")
}
withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
    ptr.baseAddress!.copyMemory(from: pathBytes, byteCount: pathBytes.count)
}
addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
if connectResult != 0 { fail("connect(\(socketPath)): \(String(cString: strerror(errno)))") }

// Apply read timeout so a wedged server doesn't hang brew forever.
var to = kReplyTimeout
setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &to, socklen_t(MemoryLayout<timeval>.size))

// MARK: - Validate server

#if !DEBUG
var token = audit_token_t()
var tokenSize = socklen_t(MemoryLayout<audit_token_t>.size)
let peerRc = withUnsafeMutablePointer(to: &token) { ptr -> Int32 in
    ptr.withMemoryRebound(to: UInt8.self, capacity: Int(tokenSize)) { _ in
        getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, ptr, &tokenSize)
    }
}
if peerRc != 0 { fail("getsockopt LOCAL_PEERTOKEN: \(String(cString: strerror(errno)))") }

let tokenData = withUnsafeBytes(of: token) { Data($0) }
let attrs: [CFString: Any] = [kSecGuestAttributeAudit: tokenData]
var secCode: SecCode?
if SecCodeCopyGuestWithAttributes(nil, attrs as CFDictionary, [], &secCode) != errSecSuccess || secCode == nil {
    fail("SecCodeCopyGuestWithAttributes failed")
}
var req: SecRequirement?
if SecRequirementCreateWithString(SteadingAskpassServerRequirement as CFString, [], &req) != errSecSuccess,
   req != nil {
    fail("SecRequirementCreateWithString failed")
}
if SecCodeCheckValidity(secCode!, [], req) != errSecSuccess {
    fail("server codesign requirement not satisfied")
}
#endif

// MARK: - Exchange

let request = SteadingAskpassWire.requestLine + "\n"
request.withCString { p in _ = write(fd, p, strlen(p)) }

// Read until we've consumed at least two lines (status + optional password).
var collected = Data()
var chunk = [UInt8](repeating: 0, count: 256)
while true {
    let n = read(fd, &chunk, chunk.count)
    if n <= 0 { break }
    collected.append(contentsOf: chunk[0..<Int(n)])
    if let _ = collected.firstIndex(of: 0x0A) {
        // Have at least a status line; keep reading briefly if more
        // content may follow (OK case has a second line).
        // Simple heuristic: if collected starts with OK\n and no
        // second newline yet, keep reading. Cap at 64K.
        if collected.count > 65_536 { break }
        let asString = String(data: collected, encoding: .utf8) ?? ""
        if asString.hasPrefix("\(SteadingAskpassWire.okLine)\n") {
            // Need a second line terminated by LF.
            let trimmed = asString.dropFirst(SteadingAskpassWire.okLine.count + 1)
            if trimmed.contains("\n") { break }
            continue
        }
        break
    }
    if collected.count > 65_536 { break }
}
close(fd)

let text = String(data: collected, encoding: .utf8) ?? ""
let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
guard let status = lines.first else { fail("empty response") }
switch status {
case SteadingAskpassWire.okLine:
    guard lines.count >= 2 else { fail("OK without password") }
    print(lines[1])
    exit(0)
case SteadingAskpassWire.cancelLine:
    exit(1)
case SteadingAskpassWire.denyLine:
    fail("server rejected this helper")
default:
    fail("unexpected server response: \(status)")
}

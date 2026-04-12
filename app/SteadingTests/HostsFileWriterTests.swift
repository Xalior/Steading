import Testing
import Foundation
import Darwin
@testable import Steading

/// Tests exercise the real `HostsFileWriter.write` implementation —
/// the same function the privileged helper calls in production.
///
/// We write to `NSTemporaryDirectory()`-relative paths so the tests
/// don't need root and don't touch `/etc/hosts`. The production code
/// path is identical; `fchown` is a no-op when the tests aren't
/// running as root, which is the only difference.
@Suite("HostsFileWriter")
struct HostsFileWriterTests {

    // MARK: - Test scaffolding

    /// Returns a freshly-generated path under the tests' own sandbox
    /// directory. Caller is responsible for cleanup.
    private func makeTempPath(name: String = "hosts-test") -> String {
        let dir = NSTemporaryDirectory()
            .appending("com.xalior.SteadingTests.\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        return "\(dir)/\(name)"
    }

    private func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    private func mode(of path: String) -> mode_t? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return st.st_mode & 0o7777
    }

    // MARK: - Round trips

    @Test("write round-trips bytes exactly")
    func roundTrip() throws {
        let path = makeTempPath()
        let payload = """
        ##
        # Host Database
        #
        127.0.0.1\tlocalhost
        # 192.168.1.10\tnas.local   ← commented-out entry
        255.255.255.255\tbroadcasthost
        ::1             localhost
        """
        let data = Data(payload.utf8)

        let result = HostsFileWriter.write(content: data, to: path)
        #expect(result == .success)

        let readBack = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(readBack == data)
    }

    @Test("overwrite preserves path and replaces content")
    func overwrite() throws {
        let path = makeTempPath()
        let first = Data("127.0.0.1 localhost\n".utf8)
        let second = Data("127.0.0.1 localhost\n10.0.0.1 router\n".utf8)

        #expect(HostsFileWriter.write(content: first, to: path) == .success)
        #expect(HostsFileWriter.write(content: second, to: path) == .success)

        let readBack = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(readBack == second)
    }

    @Test("resulting file is mode 0644")
    func modeIs0644() {
        let path = makeTempPath()
        let data = Data("127.0.0.1 localhost\n".utf8)
        #expect(HostsFileWriter.write(content: data, to: path) == .success)

        guard let m = mode(of: path) else {
            Issue.record("stat failed on written file")
            return
        }
        #expect(m == 0o644)
    }

    @Test("empty content is accepted and produces a zero-byte file")
    func emptyPayload() throws {
        let path = makeTempPath()
        #expect(HostsFileWriter.write(content: Data(), to: path) == .success)
        let readBack = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(readBack.isEmpty)
    }

    // MARK: - Failure paths

    @Test("write to nonexistent directory fails cleanly")
    func nonexistentDirectoryFails() {
        let path = "/tmp/steading-tests-does-not-exist-\(UUID().uuidString)/hosts"
        let result = HostsFileWriter.write(
            content: Data("x".utf8), to: path
        )
        guard case .failure(let reason) = result else {
            Issue.record("expected failure, got success")
            return
        }
        #expect(!reason.isEmpty)
        #expect(!fileExists(path))
    }

    @Test("write to /etc/hosts fails without root and leaves it untouched")
    func unprivilegedEtcHostsIsRejected() {
        // Precondition: we are NOT running as root. If somebody invents
        // a way to run the tests as root in future, this test stops
        // asserting what it says it asserts — so skip it rather than
        // lying about what it covers.
        guard geteuid() != 0 else { return }

        let originalData: Data
        do {
            originalData = try Data(contentsOf: URL(fileURLWithPath: "/etc/hosts"))
        } catch {
            Issue.record("could not read /etc/hosts for baseline: \(error)")
            return
        }

        let bogus = Data("# steading test — should never land\n".utf8)
        let result = HostsFileWriter.write(content: bogus, to: "/etc/hosts")
        guard case .failure = result else {
            Issue.record("unprivileged write to /etc/hosts should fail, got success")
            return
        }

        // /etc/hosts must be untouched.
        let afterData = (try? Data(contentsOf: URL(fileURLWithPath: "/etc/hosts"))) ?? Data()
        #expect(afterData == originalData)
    }
}

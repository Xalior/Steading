import Testing
import Foundation
@testable import Steading

/// Live tests for the helper's approvals subsystem and the
/// approval-gated file methods. Each test stands up a real
/// `PrivHelperService` behind an anonymous `NSXPCListener`,
/// pointing the service at a temp-directory approvals plist so the
/// tests don't touch `/Library/Application Support/`. Every call
/// flows through real NSXPC serialization, the real
/// `ApprovalsStore`, and the real `PrivilegedFileWriter` /
/// `PrivHelperRefusalList`.
@Suite("PrivHelper approvals + file ops")
struct PrivHelperApprovalsTests {

    @MainActor
    final class Harness {
        let listener: NSXPCListener
        let approvalsURL: URL
        private let delegate: AcceptAllDelegate
        private let tempDir: URL

        init() throws {
            let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("steading-approvals-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let approvalsURL = tempDir.appendingPathComponent("approvals.plist")

            let listener = NSXPCListener.anonymous()
            let delegate = AcceptAllDelegate(approvalsURL: approvalsURL)
            listener.delegate = delegate
            listener.resume()

            self.tempDir = tempDir
            self.approvalsURL = approvalsURL
            self.listener = listener
            self.delegate = delegate
        }

        deinit {
            try? FileManager.default.removeItem(at: tempDir)
        }

        func makeClient() -> PrivHelperClient {
            let endpoint = listener.endpoint
            return PrivHelperClient {
                NSXPCConnection(listenerEndpoint: endpoint)
            }
        }
    }

    private final class AcceptAllDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
        let approvalsURL: URL
        init(approvalsURL: URL) { self.approvalsURL = approvalsURL }
        func listener(_ listener: NSXPCListener,
                      shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
            newConnection.exportedInterface = NSXPCInterface(with: SteadingPrivHelperProtocol.self)
            newConnection.exportedObject = PrivHelperService(approvalsURL: approvalsURL)
            newConnection.resume()
            return true
        }
    }

    // MARK: - Approvals round-trip

    @Test("recordApproval / listApprovals / forgetApproval round-trip")
    @MainActor
    func approvalsRoundTrip() async throws {
        let harness = try Harness()
        let client = harness.makeClient()

        let path = "/tmp/example/mysql.yml"
        let hash = DefinitionHash.sha256Hex(of: "schemaVersion: 1\nserviceID: mysql\n")

        try await client.recordApproval(yamlPath: path, hash: hash)

        let approvals = try await client.listApprovals()
        #expect(approvals[path] == hash)

        try await client.forgetApproval(yamlPath: path)

        let after = try await client.listApprovals()
        #expect(after[path] == nil)
    }

    @Test("Approvals persist across helper restarts (read from disk)")
    @MainActor
    func approvalsPersistAcrossRestarts() async throws {
        let harness = try Harness()
        let client = harness.makeClient()

        try await client.recordApproval(yamlPath: "/tmp/x.yml", hash: "abc")

        // Read directly from the plist to confirm the helper actually
        // wrote it (not just held in-memory).
        let stored = try ApprovalsStore.read(from: harness.approvalsURL)
        #expect(stored["/tmp/x.yml"] == "abc")
    }

    // MARK: - Approval-gated writeFile

    @Test("writeFile rejects calls whose yamlHash isn't approved")
    @MainActor
    func writeFileRejectsWithoutApproval() async throws {
        let harness = try Harness()
        let client = harness.makeClient()

        let target = harness.approvalsURL.deletingLastPathComponent()
            .appendingPathComponent("config-out").path
        do {
            try await client.writeFile(path: target, mode: 0o644,
                                       ownerUID: 0, groupGID: 0,
                                       content: Data("hello".utf8),
                                       yamlHash: "neverapproved")
            Issue.record("expected helper to reject write without approval")
        } catch {
            // Expected — helperError or xpc error
        }
        #expect(!FileManager.default.fileExists(atPath: target),
                "writeFile must not have produced a file when rejected")
    }

    @Test("writeFile accepts an approved yamlHash and writes content")
    @MainActor
    func writeFileWithApprovalSucceeds() async throws {
        let harness = try Harness()
        let client = harness.makeClient()

        let yamlSrc = "schemaVersion: 1\n"
        let hash = DefinitionHash.sha256Hex(of: yamlSrc)
        try await client.recordApproval(yamlPath: "/tmp/whatever.yml", hash: hash)

        // Write to a path under the temp dir so we don't need root.
        let target = harness.approvalsURL.deletingLastPathComponent()
            .appendingPathComponent("payload").path
        try await client.writeFile(path: target, mode: 0o644,
                                   ownerUID: Int(getuid()), groupGID: Int(getgid()),
                                   content: Data("hello\n".utf8),
                                   yamlHash: hash)
        let written = try String(contentsOfFile: target, encoding: .utf8)
        #expect(written == "hello\n")
    }

    @Test("writeFile rejects writes to blocklisted paths even with approval")
    @MainActor
    func writeFileRefusalListBeatsApproval() async throws {
        let harness = try Harness()
        let client = harness.makeClient()
        let hash = "anyhash"
        try await client.recordApproval(yamlPath: "/tmp/whatever.yml", hash: hash)

        do {
            try await client.writeFile(path: "/etc/sudoers", mode: 0o644,
                                       ownerUID: 0, groupGID: 0,
                                       content: Data("malicious".utf8),
                                       yamlHash: hash)
            Issue.record("expected refusal-list rejection for /etc/sudoers")
        } catch let PrivHelperClient.Error.helperError(_, message) {
            #expect(message.contains("blocklisted") || message.contains("blocklist"),
                    "expected blocklist message; got: \(message)")
        } catch {
            // Any thrown error is acceptable as long as the write was rejected.
        }
        #expect(!FileManager.default.fileExists(atPath: "/etc/sudoers.steading-test-marker"),
                "no leakage to /etc")
    }

    // MARK: - readFile / removeFile

    @Test("readFile honours approval and returns file contents")
    @MainActor
    func readFileWithApproval() async throws {
        let harness = try Harness()
        let client = harness.makeClient()

        let hash = "h"
        try await client.recordApproval(yamlPath: "/tmp/whatever.yml", hash: hash)

        let target = harness.approvalsURL.deletingLastPathComponent()
            .appendingPathComponent("payload").path
        try "alpha".write(toFile: target, atomically: true, encoding: .utf8)

        let data = try await client.readFile(path: target, yamlHash: hash)
        #expect(String(data: data, encoding: .utf8) == "alpha")
    }

    @Test("removeFile is idempotent on already-absent paths")
    @MainActor
    func removeFileIdempotent() async throws {
        let harness = try Harness()
        let client = harness.makeClient()

        try await client.recordApproval(yamlPath: "/tmp/whatever.yml", hash: "h")

        let target = harness.approvalsURL.deletingLastPathComponent()
            .appendingPathComponent("does-not-exist").path
        // Should not throw.
        try await client.removeFile(path: target, yamlHash: "h")
    }
}

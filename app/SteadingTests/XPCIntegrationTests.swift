import Testing
import Foundation
import Darwin
@testable import Steading

/// End-to-end XPC tests. Spin up an anonymous `NSXPCListener` inside
/// the test process, export the **real** `PrivHelperService` on it,
/// and point a `PrivHelperClient` (via its test initializer) at the
/// listener's endpoint. Every call goes through the real NSXPC
/// serialization layer and the real service methods.
///
/// What this replaces: a trust gap where the helper's concrete
/// implementation used to be reachable only by launchd, so bugs in
/// XPC wiring (parameter encoding, reply callbacks, error propagation)
/// could only surface at runtime in the installed app. These tests
/// exercise the same production code paths in-process.
///
/// What this does NOT cover:
/// - SMAppService registration (requires real launchd and user
///   approval through System Settings).
/// - Code-sign client/helper verification (requires two signed
///   processes; tested implicitly by the production runtime).
/// - mach service name lookup.
///
/// Stubbing: the only substitution is the transport — the test wires
/// `PrivHelperClient` to an anonymous listener endpoint instead of
/// the privileged mach service. No logic is stubbed; both ends run
/// their real implementations.
@Suite("XPC integration — PrivHelperClient ↔ PrivHelperService")
struct XPCIntegrationTests {

    // MARK: - Harness

    /// Owns an anonymous `NSXPCListener` with a delegate that accepts
    /// every connection and exports a real `PrivHelperService`. The
    /// harness must stay alive for the duration of a test — when it
    /// goes out of scope the listener deinits and the endpoint stops
    /// accepting.
    @MainActor
    final class Harness {
        let listener: NSXPCListener
        private let delegate: AcceptAllDelegate

        init() {
            let listener = NSXPCListener.anonymous()
            let delegate = AcceptAllDelegate()
            listener.delegate = delegate
            listener.resume()
            self.listener = listener
            self.delegate = delegate
        }

        func makeClient() -> PrivHelperClient {
            let endpoint = listener.endpoint
            return PrivHelperClient {
                NSXPCConnection(listenerEndpoint: endpoint)
            }
        }
    }

    /// In-process NSXPCListener delegate. Accepts every connection
    /// (there is no cross-process code-sign check to make in-process)
    /// and exports the real `PrivHelperService` as the served object.
    private final class AcceptAllDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
        func listener(_ listener: NSXPCListener,
                      shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
            newConnection.exportedInterface = NSXPCInterface(with: SteadingPrivHelperProtocol.self)
            newConnection.exportedObject = PrivHelperService()
            newConnection.resume()
            return true
        }
    }

    // MARK: - Tests: ping

    @Test("helperVersion round-trips over XPC")
    @MainActor
    func helperVersionRoundTrip() async throws {
        let harness = Harness()
        let client = harness.makeClient()
        let version = try await client.helperVersion()
        #expect(version == SteadingPrivHelperVersion)
    }

    // MARK: - Tests: runCommand

    @Test("allowlisted runCommand runs the real subprocess and round-trips stdout")
    @MainActor
    func allowlistedRunCommand() async throws {
        let harness = Harness()
        let client = harness.makeClient()

        // launchctl list is allowlisted, unprivileged, read-only, and
        // always produces non-empty output on a running macOS system.
        let result = try await client.runCommand(["/bin/launchctl", "list"])
        #expect(result.exitCode == 0)
        #expect(!result.stdout.isEmpty)
    }

    @Test("non-allowlisted runCommand is rejected by the helper with -1 + reason")
    @MainActor
    func nonAllowlistedRejected() async throws {
        let harness = Harness()
        let client = harness.makeClient()

        let result = try await client.runCommand(["/bin/sh", "-c", "echo hi"])
        #expect(result.exitCode == -1)
        #expect(result.stderr.contains("not in allowlist"))
        #expect(result.stdout.isEmpty)
    }

    @Test("runCommand with empty argv throws Error.empty before hitting XPC")
    @MainActor
    func emptyArgvThrows() async throws {
        let harness = Harness()
        let client = harness.makeClient()

        await #expect(throws: PrivHelperClient.Error.self) {
            _ = try await client.runCommand([])
        }
    }

    // MARK: - Tests: writeHostsFile

    @Test("writeHostsFile rejects oversized payload client-side before XPC")
    @MainActor
    func writeHostsFileOversizeClientSide() async throws {
        let harness = Harness()
        let client = harness.makeClient()

        let oversized = String(repeating: "x", count: SteadingHostsFileMaxSize + 1)
        var caught: PrivHelperClient.Error?
        do {
            try await client.writeHostsFile(oversized)
        } catch let error as PrivHelperClient.Error {
            caught = error
        }

        guard let caught else {
            Issue.record("expected PrivHelperClient.Error, no error thrown")
            return
        }
        if case .hostsFileTooLarge(let size) = caught {
            #expect(size == SteadingHostsFileMaxSize + 1)
        } else {
            Issue.record("expected .hostsFileTooLarge, got \(caught)")
        }
    }

    @Test("writeHostsFile over XPC surfaces the helper's failure reason verbatim")
    @MainActor
    func writeHostsFileUnprivilegedFails() async throws {
        // Precondition: not root. If tests ever run as root, this
        // would actually modify /etc/hosts, which is not what the
        // test claims to assert — skip rather than lie.
        guard geteuid() != 0 else { return }

        let originalHosts = try Data(contentsOf: URL(fileURLWithPath: "/etc/hosts"))

        let harness = Harness()
        let client = harness.makeClient()

        let bogus = "# steading xpc test — must not land in /etc/hosts\n"
        var caught: Swift.Error?
        do {
            try await client.writeHostsFile(bogus)
        } catch {
            caught = error
        }

        #expect(caught != nil, "unprivileged write should fail over XPC")
        if case .hostsWriteFailed(let message) = caught as? PrivHelperClient.Error {
            #expect(!message.isEmpty)
        } else {
            Issue.record("expected .hostsWriteFailed, got \(String(describing: caught))")
        }

        // Safety assertion — the test itself must not have corrupted
        // the dev mac's /etc/hosts.
        let after = try Data(contentsOf: URL(fileURLWithPath: "/etc/hosts"))
        #expect(after == originalHosts)
    }

    // MARK: - Tests: PrivHelperService directly (no XPC)

    // These complement the XPC tests by exercising the server-side
    // code path that the client's pre-flight checks prevent from
    // being reached over XPC. Specifically: the server-side size
    // cap, which fires only if somebody bypasses the client.

    @Test("PrivHelperService rejects oversized writeHostsFile server-side")
    @MainActor
    func serverSideSizeCap() async {
        let service = PrivHelperService()
        let oversized = Data(repeating: 0x78, count: SteadingHostsFileMaxSize + 1)

        let result: (Bool, String) = await withCheckedContinuation { cont in
            service.writeHostsFile(content: oversized) { success, message in
                cont.resume(returning: (success, message))
            }
        }

        #expect(result.0 == false)
        #expect(result.1.contains("exceeds"))
        #expect(result.1.contains(String(SteadingHostsFileMaxSize)))
    }

    @Test("PrivHelperService.helperVersion returns SteadingPrivHelperVersion")
    @MainActor
    func serviceHelperVersion() async {
        let service = PrivHelperService()
        let version: String = await withCheckedContinuation { cont in
            service.helperVersion { cont.resume(returning: $0) }
        }
        #expect(version == SteadingPrivHelperVersion)
    }
}

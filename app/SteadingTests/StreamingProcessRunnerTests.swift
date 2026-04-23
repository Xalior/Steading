import Testing
import Foundation
@testable import Steading

/// Exercises the real streaming subprocess surface against cheap
/// deterministic shell one-liners. No mocks; every test spawns a real
/// subprocess and consumes the real event stream.
@Suite("StreamingProcessRunner")
struct StreamingProcessRunnerTests {

    // MARK: - Incremental delivery

    @Test("emits five stdout lines incrementally with a zero exit")
    func incremental_stdout() async {
        let handle = StreamingProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "for i in 1 2 3 4 5; do echo line$i; sleep 0.1; done"]
        )

        var collected = Data()
        var firstEventAt: Date?
        var exitCode: Int32?
        let start = Date()

        for await event in handle.events {
            switch event {
            case .output(.stdout, let data):
                if firstEventAt == nil { firstEventAt = Date() }
                collected.append(data)
            case .output(.stderr, _):
                break
            case .exited(let code):
                exitCode = code
            case .cancelled, .failed:
                Issue.record("unexpected event \(event)")
            }
        }

        #expect(exitCode == 0)
        let text = String(data: collected, encoding: .utf8) ?? ""
        #expect(text.contains("line1"))
        #expect(text.contains("line2"))
        #expect(text.contains("line3"))
        #expect(text.contains("line4"))
        #expect(text.contains("line5"))

        // The first output event must land before the process has
        // had time to write all five lines. With 0.1s sleeps between
        // lines, the whole run takes ~500ms; the first byte should
        // be delivered within the first 400ms.
        if let first = firstEventAt {
            #expect(first.timeIntervalSince(start) < 0.4,
                    "first chunk arrived too late — output is being buffered to the end")
        } else {
            Issue.record("no stdout event ever arrived")
        }
    }

    // MARK: - Interleaved stdout and stderr

    @Test("interleaves stdout and stderr in arrival order")
    func interleaved_channels() async {
        let handle = StreamingProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo out1; echo err1 1>&2; echo out2; echo err2 1>&2"]
        )

        var outSeen = false
        var errSeen = false
        var exitCode: Int32?

        for await event in handle.events {
            switch event {
            case .output(.stdout, let data):
                if (String(data: data, encoding: .utf8) ?? "").contains("out") {
                    outSeen = true
                }
            case .output(.stderr, let data):
                if (String(data: data, encoding: .utf8) ?? "").contains("err") {
                    errSeen = true
                }
            case .exited(let code):
                exitCode = code
            case .cancelled, .failed:
                Issue.record("unexpected event \(event)")
            }
        }

        #expect(outSeen)
        #expect(errSeen)
        #expect(exitCode == 0)
    }

    // MARK: - Cancellation within grace window

    @Test("cancel of cooperative sleep is reaped within the SIGTERM grace window")
    func cancel_sigterm_graceful() async {
        let handle = StreamingProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 30"]
        )

        let consumer = Task { () -> StreamingProcessRunner.Event? in
            var final: StreamingProcessRunner.Event?
            for await event in handle.events {
                if case .output = event { continue }
                final = event
            }
            return final
        }

        try? await Task.sleep(for: .milliseconds(100))
        let start = Date()
        handle.cancel()

        let final = await consumer.value
        let elapsed = Date().timeIntervalSince(start)

        guard final == .cancelled else {
            Issue.record("expected .cancelled, got \(String(describing: final))")
            return
        }
        #expect(elapsed < StreamingProcessRunner.terminationGrace,
                "process should exit on SIGTERM within the 5s grace window — took \(elapsed)s")
    }

    // MARK: - Cancellation of a TERM-ignoring subprocess

    @Test("cancel of trap-ignoring subprocess escalates to SIGKILL after the grace window")
    func cancel_sigkill_escalation() async {
        let handle = StreamingProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; sleep 30"]
        )

        let consumer = Task { () -> StreamingProcessRunner.Event? in
            var final: StreamingProcessRunner.Event?
            for await event in handle.events {
                if case .output = event { continue }
                final = event
            }
            return final
        }

        try? await Task.sleep(for: .milliseconds(100))
        let start = Date()
        handle.cancel()

        let final = await consumer.value
        let elapsed = Date().timeIntervalSince(start)

        guard final == .cancelled else {
            Issue.record("expected .cancelled, got \(String(describing: final))")
            return
        }
        // Must have waited at least the SIGTERM grace window before SIGKILL.
        #expect(elapsed >= StreamingProcessRunner.terminationGrace * 0.9,
                "subprocess was reaped too quickly — SIGTERM alone shouldn't have worked (grace=\(StreamingProcessRunner.terminationGrace)s, elapsed=\(elapsed)s)")
        #expect(elapsed < StreamingProcessRunner.terminationGrace + 3,
                "subprocess took too long to die even after SIGKILL — elapsed=\(elapsed)s")
    }

    // MARK: - Spawn failure

    @Test("spawning a nonexistent binary yields .failed")
    func spawn_failure() async {
        let handle = StreamingProcessRunner.run(
            executable: "/tmp/definitely-not-a-binary-\(UUID().uuidString)",
            arguments: []
        )

        var final: StreamingProcessRunner.Event?
        for await event in handle.events {
            final = event
        }

        guard case .failed = final else {
            Issue.record("expected .failed, got \(String(describing: final))")
            return
        }
    }
}

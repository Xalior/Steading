import Foundation

/// Generic streaming subprocess surface. Spawns an arbitrary
/// executable, streams stdout and stderr as they arrive, and reports
/// the final terminal event (normal exit, caller cancellation, or
/// spawn failure). The live log in the Brew Package Manager window
/// drives off this surface; future non-brew flows (e.g. bootstrapping
/// Homebrew at first launch) can reuse it without modification.
///
/// Cancellation semantics: `handle.cancel()` sends SIGTERM to the
/// subprocess and escalates to SIGKILL after `terminationGrace`
/// seconds if the process still lives. Any event stream ends with
/// exactly one terminal event (`.exited`, `.cancelled`, or `.failed`).
struct StreamingProcessRunner {

    enum OutputChannel: Sendable, Hashable {
        case stdout
        case stderr
    }

    enum Event: Sendable, Equatable {
        case output(OutputChannel, Data)
        case exited(Int32)
        case cancelled
        case failed(reason: String)
    }

    struct Handle: Sendable {
        let events: AsyncStream<Event>
        let cancel: @Sendable () -> Void
    }

    static let terminationGrace: TimeInterval = 5

    /// Spawn `executable` with `arguments` and return a `Handle` whose
    /// `events` stream carries output + terminal events. Call
    /// `handle.cancel()` to terminate the subprocess. `environment`,
    /// when supplied, replaces the child's env wholesale; `nil`
    /// inherits the current process's env.
    static func run(executable: String,
                    arguments: [String],
                    environment: [String: String]? = nil) -> Handle {
        let controller = Controller()

        let stream = AsyncStream<Event> { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let environment {
                process.environment = environment
            }
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    continuation.yield(.output(.stdout, data))
                }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    continuation.yield(.output(.stderr, data))
                }
            }

            process.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                // Close the read ends promptly. Draining with readToEnd()
                // would block if the subprocess left orphaned descendants
                // (a forked shell's child keeps the write end open until
                // the child itself exits).
                try? outPipe.fileHandleForReading.close()
                try? errPipe.fileHandleForReading.close()
                if controller.wasCancelled {
                    continuation.yield(.cancelled)
                } else {
                    continuation.yield(.exited(proc.terminationStatus))
                }
                continuation.finish()
            }

            do {
                try process.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                continuation.yield(.failed(reason: "spawn failed: \(error.localizedDescription)"))
                continuation.finish()
                return
            }

            controller.attach(process: process)
        }

        return Handle(events: stream, cancel: { controller.cancel() })
    }

    // MARK: - Internals

    /// Shared cancellation state. A lock guards the mutable fields so
    /// `cancel()` from any thread is safe. The SIGKILL escalation runs
    /// on a detached task rather than the lock's queue — the task's
    /// lifetime is independent of the Controller, which means the
    /// grace timer still fires even if no one holds a reference to
    /// the runner by the time it elapses.
    private final class Controller: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        func attach(process: Process) {
            lock.lock(); defer { lock.unlock() }
            self.process = process
        }

        func cancel() {
            lock.lock()
            guard !cancelled else { lock.unlock(); return }
            cancelled = true
            guard let process, process.isRunning, process.processIdentifier > 0 else {
                lock.unlock()
                return
            }
            let pid = process.processIdentifier
            process.terminate()
            lock.unlock()

            Task.detached {
                try? await Task.sleep(for: .seconds(terminationGrace))
                if kill(pid, 0) == 0 {
                    kill(pid, SIGKILL)
                }
            }
        }

        var wasCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }
    }
}

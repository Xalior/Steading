import Foundation
import Observation

/// Drives the user-triggered `brew install tailscale` for the Tailscale
/// onboarding pane. Owns the install state machine and a bounded tail
/// of the streamed brew output for display.
///
/// Installing a Homebrew *formula* needs no `sudo`, so this spawns brew
/// without `SUDO_ASKPASS` wired — a stray privilege prompt would then
/// fail fast in the output stream rather than hang on a password modal
/// the pane deliberately doesn't present. The boot-time LaunchDaemon
/// wiring (which does need the privileged helper) is a separate, later
/// flow; this button only lands the binary.
@Observable
@MainActor
final class TailscaleInstaller {

    enum State: Equatable, Sendable {
        case idle
        case installing
        case finished(success: Bool)
    }

    private(set) var state: State = .idle

    /// Bounded tail of the streamed `brew install` output, for the
    /// "Show output" disclosure. Reset at the start of each run.
    private(set) var logTail: String = ""

    /// Spawn boundary: given an argv, return a streaming process handle.
    /// Production resolves brew and runs it; tests inject canned events.
    typealias Spawn = @Sendable ([String]) -> StreamingProcessRunner.Handle

    private let spawn: Spawn
    private var task: Task<Void, Never>?

    init(spawn: @escaping Spawn = TailscaleInstaller.defaultSpawn) {
        self.spawn = spawn
    }

    /// Argv for installing the open-source Tailscale formula. Pure —
    /// exposed for tests.
    nonisolated static func installArgv() -> [String] {
        ["install", "tailscale"]
    }

    /// Kick off the install. No-op if one is already in flight.
    func install() {
        guard state != .installing else { return }
        state = .installing
        logTail = ""
        let handle = spawn(Self.installArgv())
        task = Task { [weak self] in
            var buffer = ""
            var exitCode: Int32?
            for await event in handle.events {
                switch event {
                case .output(_, let data):
                    buffer += String(data: data, encoding: .utf8) ?? ""
                    self?.logTail = BrewPackageManager.displayTail(buffer)
                case .exited(let code):
                    exitCode = code
                case .cancelled:
                    exitCode = -1
                case .failed(let reason):
                    buffer += "\n\(reason)"
                    self?.logTail = BrewPackageManager.displayTail(buffer)
                    exitCode = -1
                }
            }
            self?.finish(success: exitCode == 0)
        }
    }

    private func finish(success: Bool) {
        task = nil
        state = .finished(success: success)
    }

    /// Production spawn: locate brew at a standard path and stream
    /// `brew <argv>` with `SUDO_ASKPASS` removed (see type doc).
    nonisolated static let defaultSpawn: Spawn = { argv in
        guard let brewPath = BrewUpdateManager.defaultBrewPathResolver() else {
            let stream = AsyncStream<StreamingProcessRunner.Event> { continuation in
                continuation.yield(.failed(reason: "no brew on disk"))
                continuation.finish()
            }
            return StreamingProcessRunner.Handle(events: stream, cancel: {})
        }
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "SUDO_ASKPASS")
        return StreamingProcessRunner.run(
            executable: brewPath,
            arguments: argv,
            environment: env
        )
    }
}

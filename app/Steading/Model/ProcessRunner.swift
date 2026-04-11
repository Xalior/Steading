import Foundation

/// Minimal wrapper around `Process` for running command-line tools
/// and capturing their output. Used by the built-in service state
/// readers to talk to `launchctl`, `cupsctl`, `socketfilterfw`,
/// `pmset`, and friends.
enum ProcessRunner {

    struct Result: Sendable, Equatable {
        let exitCode: Int32
        let stdout: String
        let stderr: String

        var ok: Bool { exitCode == 0 }
    }

    /// Run a subprocess and collect its stdout and stderr. Runs on a
    /// detached task so the caller can `await` without blocking the
    /// main actor.
    static func run(_ executable: String, _ arguments: [String] = []) async -> Result {
        await Task.detached { () -> Result in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            do {
                try process.run()
            } catch {
                return Result(exitCode: -1, stdout: "", stderr: "\(error)")
            }
            process.waitUntilExit()

            let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
            let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            return Result(
                exitCode: process.terminationStatus,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? ""
            )
        }.value
    }
}

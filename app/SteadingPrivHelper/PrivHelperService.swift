import Foundation
import os.log

/// Concrete implementation of `SteadingPrivHelperProtocol`. Runs as
/// root; this is the code that actually spawns the allowlisted tools.
final class PrivHelperService: NSObject, SteadingPrivHelperProtocol {

    private let log = Logger(subsystem: "com.xalior.Steading.privhelper", category: "service")

    func helperVersion(withReply reply: @escaping (String) -> Void) {
        reply(SteadingPrivHelperVersion)
    }

    func runCommand(executable: String,
                    arguments: [String],
                    withReply reply: @escaping (Int32, Data, Data) -> Void) {
        // Enforce the allowlist first. This is the entire reason the
        // helper exists — the main app can ONLY ask for commands we
        // already know are safe to run as root.
        guard PrivHelperAllowlist.isAllowed(executable: executable, arguments: arguments) else {
            log.error("rejected disallowed command: \(executable) \(arguments.joined(separator: " "))")
            let message = "privhelper: command not in allowlist: \(executable)"
            reply(-1, Data(), message.data(using: .utf8) ?? Data())
            return
        }

        log.info("running \(executable) \(arguments.joined(separator: " "))")

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
            let message = "privhelper: failed to launch \(executable): \(error)"
            log.error("\(message)")
            reply(-1, Data(), message.data(using: .utf8) ?? Data())
            return
        }
        process.waitUntilExit()

        let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
        reply(process.terminationStatus, outData, errData)
    }
}

import Foundation

/// Detects Homebrew on this Mac. This is the one real functional unit
/// in the PoC — everything else in the app is scaffolding around it.
///
/// Design notes
/// ------------
/// - Pure functions (`parseVersion(fromBrewOutput:)`) are `public static`
///   so tests can call them directly against canned inputs.
/// - `detect()` and `readVersion(ofBrewAt:)` hit the real filesystem and
///   run the real brew binary. Tests call them directly; there are no
///   mocks or fakes that reimplement their logic.
/// - `searchPaths` is overridable so callers — including tests — can
///   point the production code at empty or nonexistent paths to exercise
///   the `.notFound` branches. That's a boundary input, not a stub.
struct BrewDetector: Sendable {

    enum Status: Sendable, Equatable {
        case installed(path: String, version: String)
        case foundButUnresponsive(path: String)
        case notFound
    }

    /// Standard Homebrew binary locations in priority order.
    /// Apple Silicon first, Intel second.
    static let standardSearchPaths: [String] = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
    ]

    let searchPaths: [String]

    init(searchPaths: [String] = Self.standardSearchPaths) {
        self.searchPaths = searchPaths
    }

    /// Probe `searchPaths` in order and return the first hit's status.
    /// - Returns: `.installed` if a brew binary is present and reports
    ///   a version; `.foundButUnresponsive` if it's on disk but doesn't
    ///   return a usable `--version`; `.notFound` if no path hit.
    func detect() async -> Status {
        for path in searchPaths where FileManager.default.isExecutableFile(atPath: path) {
            if let version = await Self.readVersion(ofBrewAt: path) {
                return .installed(path: path, version: version)
            }
            return .foundButUnresponsive(path: path)
        }
        return .notFound
    }

    /// Runs `<path> --version` and returns the parsed version string.
    /// Hits the real filesystem and spawns a real subprocess — tests
    /// call this directly against live brew.
    static func readVersion(ofBrewAt path: String) async -> String? {
        await Task.detached { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["--version"]
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                return nil
            }
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }
            guard let data = try? stdout.fileHandleForReading.readToEnd(),
                  let output = String(data: data, encoding: .utf8) else {
                return nil
            }
            return parseVersion(fromBrewOutput: output)
        }.value
    }

    /// Parse the first line of `brew --version` output into a bare
    /// version string. Example:
    ///
    ///     "Homebrew 4.4.1\nHomebrew/homebrew-core (git …)\n" -> "4.4.1"
    ///
    /// Pure, side-effect free. Tests call this directly.
    static func parseVersion(fromBrewOutput output: String) -> String? {
        guard let firstLine = output.split(whereSeparator: \.isNewline).first else {
            return nil
        }
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        let prefix = "Homebrew "
        guard trimmed.hasPrefix(prefix) else { return nil }
        let version = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return version.isEmpty ? nil : version
    }
}

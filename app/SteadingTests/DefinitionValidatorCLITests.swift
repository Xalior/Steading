import Testing
import Foundation
@testable import Steading

/// Live tests for the `steading-definition-validator` CLI binary.
///
/// The build phase that hashes bundle YAMLs runs this same binary;
/// these tests confirm its end-to-end behaviour by spawning it as a
/// subprocess from the test target. No mocks: the real binary, the
/// real loader, real YAML on disk.
@Suite("DefinitionValidatorCLI")
struct DefinitionValidatorCLITests {

    @Test("validate: malformed YAML exits non-zero (build-fail fixture)")
    func validateMalformedFailsBuild() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let badPath = dir.appendingPathComponent("broken.yml")

        // Missing required keys → schema invariant errors → non-zero.
        let bad = "schemaVersion: 1\nserviceID: example\n"
        try bad.write(to: badPath, atomically: true, encoding: .utf8)

        let result = try runValidator(args: ["validate", badPath.path])
        #expect(result.exitCode != 0,
                "validator should exit non-zero on malformed input; got \(result.exitCode)")
        #expect(!result.stderr.isEmpty,
                "validator should print a diagnostic on stderr; got empty")
    }

    @Test("validate: well-formed YAML exits zero")
    func validateGoodPassesBuild() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let goodPath = dir.appendingPathComponent("good.yml")
        try goodSource.write(to: goodPath, atomically: true, encoding: .utf8)

        let result = try runValidator(args: ["validate", goodPath.path])
        #expect(result.exitCode == 0,
                "validator should exit 0 on valid input; got \(result.exitCode)\nstderr: \(result.stderr)")
    }

    @Test("hashlist: writes plist with one entry per validated YAML")
    func hashlistWritesEntries() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try goodSource.write(to: dir.appendingPathComponent("a.yml"), atomically: true, encoding: .utf8)
        try goodSource.replacingOccurrences(of: "example", with: "another")
            .write(to: dir.appendingPathComponent("b.yml"), atomically: true, encoding: .utf8)

        let plistURL = dir.appendingPathComponent("bundle-hashes.plist")
        let result = try runValidator(args: [
            "hashlist", dir.path, "--output", plistURL.path
        ])
        #expect(result.exitCode == 0,
                "hashlist should exit 0; got \(result.exitCode)\nstderr: \(result.stderr)")
        let list = try BundleHashList.read(from: plistURL)
        #expect(list.entries.count == 2)
        #expect(list.entries["a.yml"]?.count == 64)
        #expect(list.entries["b.yml"]?.count == 64)
    }

    @Test("hashlist determinism: rebuild produces byte-identical plist for same inputs")
    func hashlistDeterministic() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try goodSource.write(to: dir.appendingPathComponent("a.yml"), atomically: true, encoding: .utf8)
        let plistA = dir.appendingPathComponent("hash-a.plist")
        let plistB = dir.appendingPathComponent("hash-b.plist")

        _ = try runValidator(args: ["hashlist", dir.path, "--output", plistA.path])
        _ = try runValidator(args: ["hashlist", dir.path, "--output", plistB.path])
        let dataA = try Data(contentsOf: plistA)
        let dataB = try Data(contentsOf: plistB)
        #expect(dataA == dataB)
    }

    // MARK: - Helpers

    private struct CommandResult { let exitCode: Int32; let stdout: String; let stderr: String }

    private func runValidator(args: [String]) throws -> CommandResult {
        let url = try locateValidatorBinary()
        let proc = Process()
        proc.executableURL = url
        proc.arguments = args
        let outPipe = Pipe(); let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        let out = String(data: (try? outPipe.fileHandleForReading.readToEnd()) ?? Data(), encoding: .utf8) ?? ""
        let err = String(data: (try? errPipe.fileHandleForReading.readToEnd()) ?? Data(), encoding: .utf8) ?? ""
        return CommandResult(exitCode: proc.terminationStatus, stdout: out, stderr: err)
    }

    /// The validator binary builds into the same products directory
    /// as the test bundle. The test bundle's `bundleURL` is
    /// `…/Build/Products/Debug/Steading.app/…/SteadingTests.xctest`,
    /// so two parents up is the products dir.
    private func locateValidatorBinary() throws -> URL {
        let bundle = Bundle(for: TestAnchor.self)
        var url = bundle.bundleURL
        // Walk up to Debug/ (the Build/Products/<config>/ dir).
        while url.lastPathComponent != "Debug" && url.path != "/" {
            url.deleteLastPathComponent()
        }
        let bin = url.appendingPathComponent("steading-definition-validator")
        guard FileManager.default.fileExists(atPath: bin.path) else {
            throw NSError(domain: "DefinitionValidatorCLITests",
                          code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "validator binary not found at \(bin.path)"])
        }
        return bin
    }

    private func makeTempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("steading-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let goodSource = """
    schemaVersion: 1
    serviceID: example
    displayName: Example
    summary: An example service.
    brewFormula: steading-example
    upstreamFormula: example
    systemUser:
      name: _example
    launchDaemon:
      label: com.xalior.steading.example
      plist:
        Label: com.xalior.steading.example
    writeTargets: []
    panes:
      - id: welcome
        title: Welcome
    """
}

/// Anchor class so `Bundle(for:)` can find the test bundle.
private final class TestAnchor {}

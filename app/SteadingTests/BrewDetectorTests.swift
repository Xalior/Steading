import Testing
import Foundation
@testable import Steading

/// All tests exercise the real `BrewDetector` code paths. The pure
/// parser function is called with canned inputs; the live `detect()`
/// and `readVersion(ofBrewAt:)` methods run the real filesystem probe
/// and real `brew --version` subprocess on this dev mac. There are no
/// stubs or fakes that reimplement BrewDetector logic.
@Suite("BrewDetector")
struct BrewDetectorTests {

    // MARK: - Pure parser — production `parseVersion` called directly.

    @Test("parseVersion: canonical multi-line brew --version output")
    func parseCanonicalOutput() {
        let raw = """
        Homebrew 4.4.1
        Homebrew/homebrew-core (git revision abc1234; last commit 2024-10-01)
        Homebrew/homebrew-cask (git revision def5678; last commit 2024-10-01)
        """
        #expect(BrewDetector.parseVersion(fromBrewOutput: raw) == "4.4.1")
    }

    @Test("parseVersion: single line, no trailing newline")
    func parseSingleLine() {
        #expect(BrewDetector.parseVersion(fromBrewOutput: "Homebrew 4.0.0") == "4.0.0")
    }

    @Test("parseVersion: trims leading and trailing whitespace")
    func parseTrimsWhitespace() {
        #expect(BrewDetector.parseVersion(fromBrewOutput: "  Homebrew 4.4.1  \n") == "4.4.1")
    }

    @Test("parseVersion: rejects output that doesn't start with 'Homebrew '")
    func parseRejectsForeignOutput() {
        #expect(BrewDetector.parseVersion(fromBrewOutput: "some-other-tool 1.0") == nil)
        #expect(BrewDetector.parseVersion(fromBrewOutput: "homebrew 4.4.1") == nil) // wrong case
    }

    @Test("parseVersion: rejects empty input")
    func parseRejectsEmpty() {
        #expect(BrewDetector.parseVersion(fromBrewOutput: "") == nil)
    }

    @Test("parseVersion: rejects 'Homebrew ' with no version after it")
    func parseRejectsNoVersion() {
        #expect(BrewDetector.parseVersion(fromBrewOutput: "Homebrew ") == nil)
        #expect(BrewDetector.parseVersion(fromBrewOutput: "Homebrew    \n") == nil)
    }

    // MARK: - Live `detect()` — hits the real filesystem + real brew.

    @Test("detect: finds Homebrew on this dev mac")
    func liveDetect() async {
        let status = await BrewDetector().detect()
        guard case let .installed(path, version) = status else {
            Issue.record("expected .installed on a dev mac with Homebrew, got \(status)")
            return
        }
        // The path returned must actually exist and be executable.
        #expect(FileManager.default.isExecutableFile(atPath: path))
        // Version must look like a version number (starts with a digit).
        #expect(!version.isEmpty)
        #expect(version.first?.isNumber == true)
    }

    @Test("detect: returns .notFound when searchPaths is empty")
    func detectNotFoundEmptyPaths() async {
        let status = await BrewDetector(searchPaths: []).detect()
        #expect(status == .notFound)
    }

    @Test("detect: returns .notFound when searchPaths all miss")
    func detectNotFoundMissingPaths() async {
        let garbage = "/tmp/definitely-not-a-real-brew-\(UUID().uuidString)"
        let status = await BrewDetector(searchPaths: [garbage]).detect()
        #expect(status == .notFound)
    }

    @Test("detect: a single explicit path that IS brew returns .installed")
    func detectSingleExplicitPath() async {
        // Find whichever of the standard paths actually exists on this
        // machine and feed it in as the sole searchPath. No mock — we
        // configure the real detector with a real boundary input.
        guard let realPath = BrewDetector.standardSearchPaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            Issue.record("no Homebrew on this dev mac — expected at least one standard path to exist")
            return
        }
        let status = await BrewDetector(searchPaths: [realPath]).detect()
        guard case let .installed(path, _) = status else {
            Issue.record("expected .installed for \(realPath), got \(status)")
            return
        }
        #expect(path == realPath)
    }

    // MARK: - Live `readVersion` — runs the real subprocess.

    @Test("readVersion: live brew binary returns a parseable version")
    func liveReadVersion() async {
        guard let realPath = BrewDetector.standardSearchPaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            Issue.record("no Homebrew on this dev mac")
            return
        }
        let version = await BrewDetector.readVersion(ofBrewAt: realPath)
        #expect(version != nil)
        #expect(version?.first?.isNumber == true)
    }

    @Test("readVersion: nonexistent path returns nil")
    func readVersionMissingPath() async {
        let v = await BrewDetector.readVersion(
            ofBrewAt: "/tmp/nope-\(UUID().uuidString)"
        )
        #expect(v == nil)
    }
}

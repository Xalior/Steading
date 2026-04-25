import Testing
import Foundation
@testable import Steading

/// Coverage for `BrewPackageManager`'s pin / unpin verbs: the pure
/// argv builders + the manager's pinned-view update on a zero-exit
/// run, surfacing on a non-zero exit.
@Suite("Brew Pin")
@MainActor
struct BrewPinTests {

    // MARK: - Pure argv builders

    @Test("pinArgv: brew pin <name>")
    func pinArgv() {
        #expect(BrewPackageManager.pinArgv(for: "git") == ["pin", "git"])
        #expect(BrewPackageManager.pinArgv(for: "python@3.11")
                == ["pin", "python@3.11"])
    }

    @Test("unpinArgv: brew unpin <name>")
    func unpinArgv() {
        #expect(BrewPackageManager.unpinArgv(for: "git") == ["unpin", "git"])
    }

    // MARK: - Manager state updates

    private func entry(_ token: String) -> BrewIndexEntry {
        BrewIndexEntry(token: token, fullToken: token,
                       tap: "homebrew/core", desc: nil, kind: .formula)
    }

    private func row(_ token: String, pinned: Bool) -> BrewPackageManager.PackageRow {
        .init(entry: entry(token), isInstalled: true, isOutdated: false, isPinned: pinned)
    }

    /// Wait until the manager's pinned view of a row matches the
    /// expected value or a per-test timeout elapses. The pin / unpin
    /// task runs asynchronously, so direct reads can race.
    private func waitFor(_ predicate: @MainActor () -> Bool,
                         timeoutSeconds: Double = 1.0) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test("pin: zero-exit brew pin flips the row's isPinned to true")
    func pin_success_flipsRow() async {
        let runner: BrewUpdateManager.Runner = { _ in
            .ran(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let manager = BrewPackageManager(runner: runner)
        manager.setIndex(rows: [row("git", pinned: false)], taps: [])

        manager.pin("git")
        await waitFor { manager.rows.first?.isPinned == true }

        #expect(manager.rows.first?.isPinned == true)
        #expect(manager.lastPinError == nil)
    }

    @Test("unpin: zero-exit brew unpin flips the row's isPinned to false")
    func unpin_success_flipsRow() async {
        let runner: BrewUpdateManager.Runner = { _ in
            .ran(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let manager = BrewPackageManager(runner: runner)
        manager.setIndex(rows: [row("git", pinned: true)], taps: [])

        manager.unpin("git")
        await waitFor { manager.rows.first?.isPinned == false }

        #expect(manager.rows.first?.isPinned == false)
        #expect(manager.lastPinError == nil)
    }

    @Test("pin: non-zero exit surfaces stderr in lastPinError; row unchanged")
    func pin_nonZeroExit_surfacesError() async {
        let runner: BrewUpdateManager.Runner = { _ in
            .ran(exitCode: 1,
                 stdout: Data(),
                 stderr: "Error: git is not installed".data(using: .utf8)!)
        }
        let manager = BrewPackageManager(runner: runner)
        manager.setIndex(rows: [row("git", pinned: false)], taps: [])

        manager.pin("git")
        await waitFor { manager.lastPinError != nil }

        #expect(manager.rows.first?.isPinned == false)
        #expect(manager.lastPinError == "Error: git is not installed")
    }

    @Test("pin: missing brew binary surfaces a specific lastPinError")
    func pin_binaryNotFound_surfacesReason() async {
        let runner: BrewUpdateManager.Runner = { _ in
            .binaryNotFound(reason: "test: missing")
        }
        let manager = BrewPackageManager(runner: runner)
        manager.setIndex(rows: [row("git", pinned: false)], taps: [])

        manager.pin("git")
        await waitFor { manager.lastPinError != nil }

        #expect(manager.rows.first?.isPinned == false)
        #expect(manager.lastPinError == "brew not available: test: missing")
    }

    @Test("pin: token not in the index is a silent no-op (no row to flip, but no error either)")
    func pin_unknownToken_isQuietNoop() async {
        let runner: BrewUpdateManager.Runner = { _ in
            .ran(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let manager = BrewPackageManager(runner: runner)
        manager.setIndex(rows: [row("git", pinned: false)], taps: [])

        manager.pin("does-not-exist")
        // Wait for the pin task to finish even though no row changes.
        try? await Task.sleep(for: .milliseconds(20))

        #expect(manager.rows.first?.isPinned == false)
        #expect(manager.lastPinError == nil)
    }
}

import Testing
import Foundation
@testable import Steading

/// State-machine tests for `BrewPackageManager.apply`. Driven through
/// the real manager with a fake `SubCallRunner` injected at the brew-
/// spawn boundary; the fake emits canned events so the manager runs
/// its full pipeline (add phase → remove phase → autoremove
/// confirmation → finish) against deterministic outcomes.
@Suite("BrewPackageManager — apply")
@MainActor
struct BrewPackageManagerApplyTests {

    // MARK: - Test fixtures

    private func entry(_ token: String,
                       full: String? = nil,
                       kind: BrewIndexEntry.Kind = .formula) -> BrewIndexEntry {
        BrewIndexEntry(token: token, fullToken: full ?? token,
                       tap: "homebrew/core", desc: nil, kind: kind)
    }

    private func row(_ token: String,
                     installed: Bool = false,
                     outdated: Bool = false,
                     pinned: Bool = false,
                     kind: BrewIndexEntry.Kind = .formula) -> BrewPackageManager.PackageRow {
        BrewPackageManager.PackageRow(
            entry: entry(token, kind: kind),
            isInstalled: installed,
            isOutdated: outdated,
            isPinned: pinned
        )
    }

    // MARK: - Fake sub-call runner

    /// Records the argv of every sub-call spawn and replies with a
    /// scripted sequence of canned event lists. One list per spawn,
    /// in the order spawns arrive. Each event list ends with one
    /// `.finished(...)` to terminate the stream.
    private final class FakeSpawn: @unchecked Sendable {
        private let lock = NSLock()
        private var scripts: [[BrewPackageManager.SubCallEvent]] = []
        private(set) var calls: [[String]] = []

        func script(_ events: [BrewPackageManager.SubCallEvent]) {
            lock.lock(); defer { lock.unlock() }
            scripts.append(events)
        }

        func runner() -> BrewPackageManager.SubCallRunner {
            return { argv in
                self.lock.lock()
                self.calls.append(argv)
                let events = self.scripts.isEmpty
                    ? [BrewPackageManager.SubCallEvent.finished(.success)]
                    : self.scripts.removeFirst()
                self.lock.unlock()

                let stream = AsyncStream<BrewPackageManager.SubCallEvent> { continuation in
                    Task {
                        for event in events {
                            continuation.yield(event)
                        }
                        continuation.finish()
                    }
                }
                return BrewPackageManager.SubCallHandle(events: stream, cancel: {})
            }
        }
    }

    /// Pump the run loop until the manager settles back to `.idle` or
    /// pauses on the autoremove confirmation. The Apply pipeline runs
    /// in a Task; this drives the main-actor scheduler so its state
    /// transitions become observable.
    private func waitFor(_ predicate: @MainActor () -> Bool,
                         timeoutSeconds: Double = 1.0) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    // MARK: - The empty-mark boundary

    @Test("apply: no marked rows → pipeline is a no-op (state stays idle, no spawns)")
    func apply_emptyMarks_isNoop() async {
        let fake = FakeSpawn()
        let manager = BrewPackageManager(subCallRunner: fake.runner())
        manager.setIndex(rows: [row("git", installed: true, outdated: true)],
                         taps: [])
        // No marks set.
        manager.apply()
        // Wait briefly to confirm no async work happens.
        try? await Task.sleep(for: .milliseconds(20))
        #expect(manager.state == .idle)
        #expect(fake.calls.isEmpty)
        #expect(manager.recentApplyOutcome == nil)
    }

    // MARK: - Add-only path (no remove → no autoremove dialog)

    @Test("apply: add-only marks → upgrade then install run; remove and autoremove are skipped")
    func apply_addOnly_runsUpgradeThenInstall() async {
        let fake = FakeSpawn()
        fake.script([.output("Upgrading git...\n"), .finished(.success)])
        fake.script([.output("Installing jq...\n"), .finished(.success)])
        let manager = BrewPackageManager(subCallRunner: fake.runner())
        manager.setIndex(rows: [
            row("git", installed: true, outdated: true),
            row("jq", installed: false),
        ], taps: [])
        manager.mark("git", true)
        manager.mark("jq", true)

        manager.apply()
        await waitFor { manager.state == .idle }

        #expect(fake.calls == [["upgrade", "git"], ["install", "jq"]])
        #expect(manager.recentApplyOutcome == .success)
        #expect(manager.applyLog.contains("Upgrading git"))
        #expect(manager.applyLog.contains("Installing jq"))
        #expect(!manager.pendingAutoremoveConfirmation)
    }

    // MARK: - Remove-only path (presents autoremove dialog)

    @Test("apply: remove-only marks → uninstall runs and the autoremove dialog is presented")
    func apply_removeOnly_presentsAutoremoveDialog() async {
        let fake = FakeSpawn()
        fake.script([.output("Uninstalling neovim...\n"), .finished(.success)])
        let manager = BrewPackageManager(subCallRunner: fake.runner())
        manager.setIndex(rows: [
            row("neovim", installed: true, outdated: false),
        ], taps: [])
        manager.mark("neovim", true)

        manager.apply()
        await waitFor { manager.pendingAutoremoveConfirmation }

        #expect(manager.state == .applying)
        #expect(fake.calls == [["uninstall", "neovim"]])
        #expect(manager.pendingAutoremoveConfirmation)

        // Decline the dialog.
        manager.confirmAutoremove(false)
        await waitFor { manager.state == .idle }

        #expect(fake.calls == [["uninstall", "neovim"]])
        #expect(manager.recentApplyOutcome == .success)
        #expect(!manager.pendingAutoremoveConfirmation)
    }

    @Test("apply: autoremove dialog accepted → brew autoremove runs and pipeline finishes successfully")
    func apply_autoremoveYes_runsAutoremove() async {
        let fake = FakeSpawn()
        fake.script([.finished(.success)])                     // uninstall
        fake.script([.output("Autoremoving cruft...\n"),
                     .finished(.success)])                     // autoremove
        let manager = BrewPackageManager(subCallRunner: fake.runner())
        manager.setIndex(rows: [row("neovim", installed: true)], taps: [])
        manager.mark("neovim", true)

        manager.apply()
        await waitFor { manager.pendingAutoremoveConfirmation }
        manager.confirmAutoremove(true)
        await waitFor { manager.state == .idle }

        #expect(fake.calls == [["uninstall", "neovim"], ["autoremove"]])
        #expect(manager.recentApplyOutcome == .success)
        #expect(manager.applyLog.contains("Autoremoving"))
    }

    // MARK: - Add + remove path (both phases run)

    @Test("apply: mixed marks → upgrade, install, uninstall all run; autoremove dialog appears after uninstall")
    func apply_mixed_runsAllPhases() async {
        let fake = FakeSpawn()
        fake.script([.finished(.success)])  // upgrade
        fake.script([.finished(.success)])  // install
        fake.script([.finished(.success)])  // uninstall
        let manager = BrewPackageManager(subCallRunner: fake.runner())
        manager.setIndex(rows: [
            row("git", installed: true, outdated: true),
            row("jq", installed: false),
            row("neovim", installed: true, outdated: false),
        ], taps: [])
        manager.mark("git", true)
        manager.mark("jq", true)
        manager.mark("neovim", true)

        manager.apply()
        await waitFor { manager.pendingAutoremoveConfirmation }
        #expect(fake.calls == [["upgrade", "git"], ["install", "jq"], ["uninstall", "neovim"]])

        manager.confirmAutoremove(false)
        await waitFor { manager.state == .idle }
        #expect(manager.recentApplyOutcome == .success)
    }

    // MARK: - Partial-failure rule

    @Test("apply: non-zero upgrade exit halts the pipeline; install / uninstall do not run")
    func apply_partialFailure_haltsOnUpgrade() async {
        let fake = FakeSpawn()
        fake.script([.output("E: upgrade failed\n"),
                     .finished(.failed(exitCode: 1))])
        let manager = BrewPackageManager(subCallRunner: fake.runner())
        manager.setIndex(rows: [
            row("git", installed: true, outdated: true),
            row("jq", installed: false),
            row("neovim", installed: true, outdated: false),
        ], taps: [])
        manager.mark("git", true)
        manager.mark("jq", true)
        manager.mark("neovim", true)

        manager.apply()
        await waitFor { manager.state == .idle }

        #expect(fake.calls == [["upgrade", "git"]])
        #expect(manager.recentApplyOutcome == .failed(exitCode: 1))
        #expect(manager.applyLog.contains("upgrade failed"))
        #expect(!manager.pendingAutoremoveConfirmation)
    }

    @Test("apply: non-zero uninstall exit halts the pipeline; autoremove is not offered")
    func apply_partialFailure_haltsOnUninstall_noAutoremovePrompt() async {
        let fake = FakeSpawn()
        fake.script([.finished(.success)])                     // upgrade
        fake.script([.finished(.success)])                     // install
        fake.script([.output("E: uninstall failed\n"),
                     .finished(.failed(exitCode: 2))])         // uninstall
        let manager = BrewPackageManager(subCallRunner: fake.runner())
        manager.setIndex(rows: [
            row("git", installed: true, outdated: true),
            row("jq", installed: false),
            row("neovim", installed: true, outdated: false),
        ], taps: [])
        manager.mark("git", true)
        manager.mark("jq", true)
        manager.mark("neovim", true)

        manager.apply()
        await waitFor { manager.state == .idle }

        #expect(fake.calls == [["upgrade", "git"], ["install", "jq"], ["uninstall", "neovim"]])
        #expect(manager.recentApplyOutcome == .failed(exitCode: 2))
        #expect(!manager.pendingAutoremoveConfirmation)
    }

    @Test("apply: non-zero autoremove exit surfaces as a failed outcome")
    func apply_autoremoveFailure_surfaces() async {
        let fake = FakeSpawn()
        fake.script([.finished(.success)])                     // uninstall
        fake.script([.finished(.failed(exitCode: 5))])         // autoremove
        let manager = BrewPackageManager(subCallRunner: fake.runner())
        manager.setIndex(rows: [row("neovim", installed: true)], taps: [])
        manager.mark("neovim", true)

        manager.apply()
        await waitFor { manager.pendingAutoremoveConfirmation }
        manager.confirmAutoremove(true)
        await waitFor { manager.state == .idle }

        #expect(manager.recentApplyOutcome == .failed(exitCode: 5))
    }

    // MARK: - Cancel

    @Test("cancelApply: cancel during the autoremove pause finishes the pipeline cleanly")
    func cancel_duringAutoremovePrompt_finishes() async {
        let fake = FakeSpawn()
        fake.script([.finished(.success)])  // uninstall
        let manager = BrewPackageManager(subCallRunner: fake.runner())
        manager.setIndex(rows: [row("neovim", installed: true)], taps: [])
        manager.mark("neovim", true)

        manager.apply()
        await waitFor { manager.pendingAutoremoveConfirmation }
        manager.cancelApply()
        await waitFor { manager.state == .idle }

        // No autoremove sub-call ran — cancel during prompt is treated
        // as declining the dialog, not a destructive interrupt.
        #expect(fake.calls == [["uninstall", "neovim"]])
        #expect(manager.recentApplyOutcome == .success)
    }
}

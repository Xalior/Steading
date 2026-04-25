import Testing
import Foundation
@testable import Steading

/// Pure-helper tests for `BrewPackageManager`. State-machine tests
/// (Apply pipeline, pin/unpin, autoremove confirmation) live alongside
/// these in subsequent commits and exercise the real manager through a
/// mock-runner DI seam.
@Suite("BrewPackageManager — pure")
@MainActor
struct BrewPackageManagerTests {

    // MARK: - Fixture builders

    private func entry(_ token: String,
                       full: String? = nil,
                       tap: String = "homebrew/core",
                       desc: String? = nil,
                       kind: BrewIndexEntry.Kind = .formula) -> BrewIndexEntry {
        BrewIndexEntry(
            token: token,
            fullToken: full ?? token,
            tap: tap,
            desc: desc,
            kind: kind
        )
    }

    private func row(_ token: String,
                     full: String? = nil,
                     installed: Bool = false,
                     outdated: Bool = false,
                     pinned: Bool = false,
                     tap: String = "homebrew/core",
                     desc: String? = nil,
                     kind: BrewIndexEntry.Kind = .formula) -> BrewPackageManager.PackageRow {
        BrewPackageManager.PackageRow(
            entry: entry(token, full: full, tap: tap, desc: desc, kind: kind),
            isInstalled: installed,
            isOutdated: outdated,
            isPinned: pinned
        )
    }

    // MARK: - Verb derivation (the marking-model table)

    @Test("verb: not installed → install")
    func verb_notInstalled_install() {
        let r = row("git", installed: false, outdated: false)
        #expect(BrewPackageManager.verb(for: r) == .install)
    }

    @Test("verb: installed and outdated → upgrade")
    func verb_outdated_upgrade() {
        let r = row("git", installed: true, outdated: true)
        #expect(BrewPackageManager.verb(for: r) == .upgrade)
    }

    @Test("verb: installed and current → remove")
    func verb_current_remove() {
        let r = row("git", installed: true, outdated: false)
        #expect(BrewPackageManager.verb(for: r) == .remove)
    }

    // MARK: - Apply argv builder

    @Test("applyArgv: empty input yields empty argv (no sub-calls)")
    func applyArgv_empty() {
        let result = BrewPackageManager.applyArgv(for: [])
        #expect(result == .init(upgrades: [], installs: [], removes: []))
        #expect(result.isEmpty)
    }

    @Test("applyArgv: mixed states fan out into upgrades / installs / removes")
    func applyArgv_mixed() {
        let rows = [
            row("git", installed: true, outdated: true),                    // upgrade
            row("jq", installed: false),                                    // install
            row("neovim", installed: true, outdated: false),                // remove
            row("python@3.11", installed: true, outdated: true),            // upgrade
            row("firefox", installed: false, kind: .cask),                  // install
            row("docker-desktop", installed: true, outdated: false,
                kind: .cask),                                               // remove
        ]
        let result = BrewPackageManager.applyArgv(for: rows)
        #expect(result.upgrades == ["git", "python@3.11"])
        #expect(result.installs == ["jq", "firefox"])
        #expect(result.removes == ["neovim", "docker-desktop"])
        #expect(!result.isEmpty)
    }

    @Test("applyArgv: tap-namespaced entries pass through fullToken (so brew install resolves the tap)")
    func applyArgv_tappedFullToken() {
        let rows = [
            row("tart", full: "cirruslabs/cli/tart",
                installed: false, tap: "cirruslabs/cli"),
            row("chamber", full: "cirruslabs/cli/chamber",
                installed: false, tap: "cirruslabs/cli", kind: .cask),
        ]
        let result = BrewPackageManager.applyArgv(for: rows)
        #expect(result.installs == ["cirruslabs/cli/tart", "cirruslabs/cli/chamber"])
        #expect(result.upgrades == [])
        #expect(result.removes == [])
    }

    // MARK: - Status-mode predicates

    @Test("statusFilter: installed matches installed regardless of outdated/pinned")
    func statusFilter_installed() {
        #expect(BrewPackageManager.matches(row("a", installed: true),
                                           statusFilter: .installed))
        #expect(BrewPackageManager.matches(row("b", installed: true, outdated: true),
                                           statusFilter: .installed))
        #expect(!BrewPackageManager.matches(row("c", installed: false),
                                            statusFilter: .installed))
    }

    @Test("statusFilter: notInstalled is the inverse of installed")
    func statusFilter_notInstalled() {
        #expect(BrewPackageManager.matches(row("a", installed: false),
                                           statusFilter: .notInstalled))
        #expect(!BrewPackageManager.matches(row("b", installed: true),
                                            statusFilter: .notInstalled))
    }

    @Test("statusFilter: upgradable matches isOutdated rows only")
    func statusFilter_upgradable() {
        #expect(BrewPackageManager.matches(row("a", installed: true, outdated: true),
                                           statusFilter: .upgradable))
        #expect(!BrewPackageManager.matches(row("b", installed: true, outdated: false),
                                            statusFilter: .upgradable))
    }

    @Test("statusFilter: pinned matches pinned regardless of installed/outdated")
    func statusFilter_pinned() {
        #expect(BrewPackageManager.matches(row("a", installed: true, pinned: true),
                                           statusFilter: .pinned))
        #expect(!BrewPackageManager.matches(row("b", installed: true, pinned: false),
                                            statusFilter: .pinned))
        // A pinned row that's somehow not installed (transient state)
        // still appears under the pinned filter — the filter is on
        // `isPinned`, not derived from install state.
        #expect(BrewPackageManager.matches(row("c", installed: false, pinned: true),
                                           statusFilter: .pinned))
    }

    // MARK: - Origin-mode predicate

    @Test("origin: matches by tap exactly")
    func origin_match() {
        let r = row("tart", tap: "cirruslabs/cli")
        #expect(BrewPackageManager.matches(r, originTap: "cirruslabs/cli"))
        #expect(!BrewPackageManager.matches(r, originTap: "homebrew/core"))
    }

    // MARK: - Search predicate

    @Test("search: case-insensitive substring against name")
    func search_byName() {
        let r = row("JSON-Tool", desc: "lightweight tool")
        #expect(BrewPackageManager.matches(r, search: "json"))
        #expect(BrewPackageManager.matches(r, search: "TOOL"))
        #expect(!BrewPackageManager.matches(r, search: "rust"))
    }

    @Test("search: case-insensitive substring against desc")
    func search_byDesc() {
        let r = row("xyz", desc: "Lightweight and flexible command-line JSON processor")
        #expect(BrewPackageManager.matches(r, search: "json"))
        #expect(BrewPackageManager.matches(r, search: "command"))
        #expect(BrewPackageManager.matches(r, search: "FLEX"))
    }

    @Test("search: matches fullToken so a tap prefix surfaces tap packages")
    func search_byFullToken() {
        let r = row("tart", full: "cirruslabs/cli/tart", tap: "cirruslabs/cli")
        #expect(BrewPackageManager.matches(r, search: "cirruslabs"))
    }

    @Test("search: empty needle never matches")
    func search_emptyNeverMatches() {
        let r = row("git", desc: "anything")
        #expect(!BrewPackageManager.matches(r, search: ""))
    }

    @Test("search: nil desc is tolerated, returns false on desc-only matches")
    func search_nilDesc() {
        let r = row("git", desc: nil)
        #expect(BrewPackageManager.matches(r, search: "git"))
        #expect(!BrewPackageManager.matches(r, search: "anything-else"))
    }

    // MARK: - Buttons

    @Test("buttons: idle with no marks — only Check Now enabled; per-row stays on")
    func buttons_idleNoMarks() {
        let b = BrewPackageManager.buttons(state: .idle, markedCount: 0, upgradableCount: 0)
        #expect(b.checkNowEnabled)
        #expect(!b.markAllEnabled)
        #expect(!b.applyEnabled)
        #expect(!b.cancelEnabled)
        #expect(b.perRowEnabled)
    }

    @Test("buttons: idle with marks — Apply enabled")
    func buttons_idleWithMarks() {
        let b = BrewPackageManager.buttons(state: .idle, markedCount: 2, upgradableCount: 5)
        #expect(b.applyEnabled)
        #expect(b.markAllEnabled)
        #expect(b.checkNowEnabled)
        #expect(!b.cancelEnabled)
    }

    @Test("buttons: applying — only Cancel enabled, per-row disabled")
    func buttons_applying() {
        let b = BrewPackageManager.buttons(state: .applying, markedCount: 2, upgradableCount: 3)
        #expect(!b.applyEnabled)
        #expect(!b.checkNowEnabled)
        #expect(!b.markAllEnabled)
        #expect(b.cancelEnabled)
        #expect(!b.perRowEnabled)
    }

    @Test("buttons: loading — Check Now disabled (already in flight); per-row stays on")
    func buttons_loading() {
        let b = BrewPackageManager.buttons(state: .loading, markedCount: 0, upgradableCount: 0)
        #expect(!b.checkNowEnabled)
        #expect(!b.applyEnabled)
        #expect(!b.markAllEnabled)
        #expect(!b.cancelEnabled)
        #expect(b.perRowEnabled)
    }

    @Test("buttons: failed — Check Now stays enabled (so the user can retry)")
    func buttons_failed() {
        let b = BrewPackageManager.buttons(state: .failed(message: "x"),
                                           markedCount: 0, upgradableCount: 0)
        #expect(b.checkNowEnabled)
        #expect(!b.applyEnabled)
        #expect(!b.markAllEnabled)
        #expect(!b.cancelEnabled)
        #expect(b.perRowEnabled)
    }
}

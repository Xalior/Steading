import Testing
import Foundation
@testable import Steading

/// Pure-function coverage for the Brew Package Manager window:
/// `brew upgrade` argv construction and the button-enablement table.
@Suite("Brew Apply — pure")
struct BrewApplyPureTests {

    // MARK: - brewUpgradeArgv

    @Test("brewUpgradeArgv: empty package list yields bare 'upgrade'")
    func argv_empty() {
        #expect(BrewUpdateManager.brewUpgradeArgv(for: []) == ["upgrade"])
    }

    @Test("brewUpgradeArgv: single package, names passed verbatim")
    func argv_single() {
        let pkg = OutdatedPackage(name: "neovim", installedVersion: "0.12.1",
                                  availableVersion: "0.12.2", kind: .formula)
        #expect(BrewUpdateManager.brewUpgradeArgv(for: [pkg]) == ["upgrade", "neovim"])
    }

    @Test("brewUpgradeArgv: multiple packages, order preserved, awkward names verbatim")
    func argv_multiple_verbatim() {
        let pkgs = [
            OutdatedPackage(name: "python@3.11", installedVersion: "3.11.0",
                            availableVersion: "3.11.2", kind: .formula),
            OutdatedPackage(name: "mysql-client@8.4", installedVersion: "8.4.8",
                            availableVersion: "8.4.9", kind: .formula),
            OutdatedPackage(name: "zulu@17", installedVersion: "17.0.18",
                            availableVersion: "17.0.19", kind: .cask),
        ]
        #expect(BrewUpdateManager.brewUpgradeArgv(for: pkgs) ==
                ["upgrade", "python@3.11", "mysql-client@8.4", "zulu@17"])
    }

    // MARK: - Button enablement

    private func pkg(_ name: String) -> OutdatedPackage {
        OutdatedPackage(name: name, installedVersion: "1", availableVersion: "2",
                        kind: .formula)
    }

    @Test("buttons: idle with nothing pending — only Check Now enabled")
    func buttons_idle_nothing() {
        let b = BrewUpdateManager.buttons(state: .idle(count: 0),
                                          markedCount: 0, outdatedCount: 0)
        #expect(b.checkNowEnabled)
        #expect(!b.markAllEnabled)
        #expect(!b.applyEnabled)
        #expect(!b.cancelEnabled)
        #expect(b.perRowEnabled)
    }

    @Test("buttons: idle with pending packages and none marked")
    func buttons_idle_with_pending_none_marked() {
        let b = BrewUpdateManager.buttons(state: .idle(count: 3),
                                          markedCount: 0, outdatedCount: 3)
        #expect(b.checkNowEnabled)
        #expect(b.markAllEnabled)
        #expect(!b.applyEnabled)
        #expect(!b.cancelEnabled)
        #expect(b.perRowEnabled)
    }

    @Test("buttons: idle with pending packages and some marked — Apply enabled")
    func buttons_idle_with_pending_marked() {
        let b = BrewUpdateManager.buttons(state: .idle(count: 3),
                                          markedCount: 2, outdatedCount: 3)
        #expect(b.applyEnabled)
        #expect(b.markAllEnabled)
        #expect(b.checkNowEnabled)
        #expect(!b.cancelEnabled)
        #expect(b.perRowEnabled)
    }

    @Test("buttons: checking — Mark All / Check Now / Apply all disabled; per-row still on")
    func buttons_checking() {
        let b = BrewUpdateManager.buttons(state: .checking,
                                          markedCount: 2, outdatedCount: 3)
        #expect(!b.checkNowEnabled)
        #expect(!b.markAllEnabled)
        #expect(!b.applyEnabled)
        #expect(!b.cancelEnabled)
        #expect(b.perRowEnabled)
    }

    @Test("buttons: applying — only Cancel enabled; per-row disabled")
    func buttons_applying() {
        let b = BrewUpdateManager.buttons(state: .applying,
                                          markedCount: 2, outdatedCount: 3)
        #expect(!b.checkNowEnabled)
        #expect(!b.markAllEnabled)
        #expect(!b.applyEnabled)
        #expect(b.cancelEnabled)
        #expect(!b.perRowEnabled)
    }

    @Test("buttons: failed with pending — Check Now enabled to retry; Mark All needs an outdated row")
    func buttons_failed() {
        let b = BrewUpdateManager.buttons(state: .failed(message: "x"),
                                          markedCount: 0, outdatedCount: 0)
        #expect(b.checkNowEnabled)
        #expect(!b.markAllEnabled)
        #expect(!b.applyEnabled)
        #expect(!b.cancelEnabled)
        #expect(b.perRowEnabled)
    }
}

import Testing
import ServiceManagement
@testable import Steading

/// Tests call `AppState`'s pure static helpers directly with canned
/// inputs — the same functions the live instance uses at runtime.
/// No stubs, no parallel reimplementation.
@Suite("AppState")
@MainActor
struct AppStateTests {

    // MARK: - mapHelperStatus — pure mapper from SMAppService.Status.

    @Test("mapHelperStatus: .enabled round-trips")
    func mapEnabled() {
        #expect(AppState.mapHelperStatus(.enabled) == .enabled)
    }

    @Test("mapHelperStatus: .requiresApproval round-trips")
    func mapRequiresApproval() {
        #expect(AppState.mapHelperStatus(.requiresApproval) == .requiresApproval)
    }

    @Test("mapHelperStatus: .notRegistered round-trips")
    func mapNotRegistered() {
        #expect(AppState.mapHelperStatus(.notRegistered) == .notRegistered)
    }

    @Test("mapHelperStatus: .notFound round-trips")
    func mapNotFound() {
        #expect(AppState.mapHelperStatus(.notFound) == .notFound)
    }

    // MARK: - isReady — the onboarding gate.

    private var brewInstalled: AppState.BrewCheckState {
        .ready(.installed(path: "/opt/homebrew/bin/brew", version: "4.4.1"))
    }

    @Test("isReady: true when brew installed AND helper enabled")
    func readyBoth() {
        #expect(AppState.isReady(
            brewCheck: brewInstalled,
            helperCheck: .ready(.enabled)
        ))
    }

    @Test("isReady: false when brew check hasn't resolved yet")
    func notReadyBrewPending() {
        #expect(!AppState.isReady(
            brewCheck: .idle,
            helperCheck: .ready(.enabled)
        ))
        #expect(!AppState.isReady(
            brewCheck: .checking,
            helperCheck: .ready(.enabled)
        ))
    }

    @Test("isReady: false when brew is not installed")
    func notReadyBrewNotFound() {
        #expect(!AppState.isReady(
            brewCheck: .ready(.notFound),
            helperCheck: .ready(.enabled)
        ))
    }

    @Test("isReady: false when brew found but unresponsive")
    func notReadyBrewUnresponsive() {
        #expect(!AppState.isReady(
            brewCheck: .ready(.foundButUnresponsive(path: "/opt/homebrew/bin/brew")),
            helperCheck: .ready(.enabled)
        ))
    }

    @Test("isReady: false when helper is not enabled")
    func notReadyHelperPendingStates() {
        let brew = brewInstalled
        #expect(!AppState.isReady(brewCheck: brew, helperCheck: .idle))
        #expect(!AppState.isReady(brewCheck: brew, helperCheck: .checking))
        #expect(!AppState.isReady(
            brewCheck: brew, helperCheck: .ready(.notRegistered)
        ))
        #expect(!AppState.isReady(
            brewCheck: brew, helperCheck: .ready(.requiresApproval)
        ))
        #expect(!AppState.isReady(
            brewCheck: brew, helperCheck: .ready(.notFound)
        ))
        #expect(!AppState.isReady(
            brewCheck: brew, helperCheck: .ready(.unknown)
        ))
    }
}

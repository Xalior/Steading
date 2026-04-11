import Foundation
import Observation
import ServiceManagement

/// Observable app-wide state. Owns the `BrewDetector` result, the
/// privileged helper's `SMAppService` status, the currently selected
/// sidebar item, and the computed `isReady` flag that drives the
/// onboarding → main-UI transition.
@Observable
@MainActor
final class AppState {

    enum BrewCheckState: Equatable {
        case idle
        case checking
        case ready(BrewDetector.Status)
    }

    /// Local mirror of `SMAppService.Status` — decoupled so the rest
    /// of the app (and tests) don't have to import ServiceManagement.
    enum HelperStatus: Sendable, Equatable {
        case notRegistered
        case enabled
        case requiresApproval
        case notFound
        case unknown
    }

    enum HelperCheckState: Equatable {
        case idle
        case checking
        case ready(HelperStatus)
    }

    var brewCheck: BrewCheckState = .idle
    var helperCheck: HelperCheckState = .idle
    var registrationError: String?
    var selection: CatalogItem.ID?

    private let detector: BrewDetector

    init(detector: BrewDetector = BrewDetector()) {
        self.detector = detector
    }

    // MARK: - Brew

    func refreshBrewStatus() async {
        brewCheck = .checking
        let status = await detector.detect()
        brewCheck = .ready(status)
    }

    // MARK: - Privileged helper

    func refreshHelperStatus() {
        helperCheck = .checking
        helperCheck = .ready(Self.mapHelperStatus(PrivHelperClient.shared.status))
    }

    /// Attempt to register the privileged helper via SMAppService.
    /// On first run this typically lands in `.requiresApproval` —
    /// that isn't an error, so we swallow the matching thrown case
    /// and let `refreshHelperStatus()` surface it via `helperCheck`.
    func registerHelper() {
        registrationError = nil
        do {
            try PrivHelperClient.shared.registerIfNeeded()
        } catch let error as PrivHelperClient.Error {
            if case .requiresApproval = error {
                // Expected first-run path; card will show the
                // pending-approval state via helperCheck below.
            } else {
                registrationError = error.localizedDescription
            }
        } catch {
            registrationError = error.localizedDescription
        }
        refreshHelperStatus()
    }

    // MARK: - Onboarding readiness

    /// True when all prerequisites are met — Homebrew is installed
    /// AND the privileged helper is registered and enabled. When
    /// this flips true, `SteadingApp`'s root view switches from
    /// `OnboardingView` to `ContentView`.
    var isReady: Bool {
        guard case .ready(.installed) = brewCheck else { return false }
        guard case .ready(.enabled) = helperCheck else { return false }
        return true
    }

    // MARK: - Pure helpers (exposed for tests)

    /// Map `SMAppService.Status` into our local `HelperStatus` enum.
    /// Pure function — tests can feed canned `SMAppService.Status`
    /// values directly and assert the mapping without touching the
    /// real helper registration.
    static func mapHelperStatus(_ smStatus: SMAppService.Status) -> HelperStatus {
        switch smStatus {
        case .notRegistered:    return .notRegistered
        case .enabled:          return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound:         return .notFound
        @unknown default:       return .unknown
        }
    }

    /// Evaluate the readiness rule for arbitrary input states.
    /// Pure — exposed for tests so they can exercise every branch
    /// of the onboarding gate without standing up a full AppState.
    static func isReady(brewCheck: BrewCheckState,
                        helperCheck: HelperCheckState) -> Bool {
        guard case .ready(.installed) = brewCheck else { return false }
        guard case .ready(.enabled) = helperCheck else { return false }
        return true
    }
}

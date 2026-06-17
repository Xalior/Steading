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

    enum TailscaleCheckState: Equatable {
        case idle
        case checking
        case ready(TailscaleDetector.Status)
    }

    var brewCheck: BrewCheckState = .idle
    var helperCheck: HelperCheckState = .idle
    /// Tailscale flavour present on this Mac. Detected once at launch
    /// (nothing removes Tailscale out from under a running app, and the
    /// MAS→open-source migration ends in a reboot that restarts the
    /// app), then refreshed only after this app's own `brew install`.
    var tailscaleCheck: TailscaleCheckState = .idle
    var registrationError: String?
    var selection: CatalogItem.ID?

    /// Merged set of bundle + external service definitions, with
    /// approval status. Driven by `loadDefinitionRegistry()` once
    /// the helper is reachable.
    let definitionRegistry = DefinitionRegistry()

    private let detector: BrewDetector
    private let tailscaleDetector: TailscaleDetector

    init(detector: BrewDetector = BrewDetector(),
         tailscaleDetector: TailscaleDetector = TailscaleDetector()) {
        self.detector = detector
        self.tailscaleDetector = tailscaleDetector
    }

    // MARK: - Definition registry

    /// Scan the bundle's ServiceDefinitions/ directory and the user's
    /// external data dir, decode each YAML, fetch the helper's
    /// current approvals plist, and merge into the registry. Pending
    /// approvals (records flagged `needsApproval`) gate the
    /// transition to `ContentView`.
    func loadDefinitionRegistry() async {
        let bundleDir = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/ServiceDefinitions")
        let bundleHashList = bundleDir.appendingPathComponent(".bundle-hashes.plist")
        let externalDir = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first?
            .appendingPathComponent("Steading/ServiceDefinitions")
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/Steading/ServiceDefinitions")
        let approvals = (try? await PrivHelperClient.shared.listApprovals()) ?? [:]
        definitionRegistry.loadAll(
            bundleDirectory: bundleDir,
            bundleHashListURL: bundleHashList,
            externalDirectory: externalDir,
            currentApprovals: approvals
        )
    }

    /// Run the consent challenge for `record`, persist via the
    /// helper, and mark the registry record approved on success.
    func approve(record: DefinitionRecord) async throws {
        try AdminAuthorization.challenge(
            prompt: "Steading needs your approval to load \(record.serviceID).yml from \(record.yamlPath)."
        )
        try await PrivHelperClient.shared.recordApproval(
            yamlPath: record.yamlPath,
            hash: record.hash
        )
        definitionRegistry.markApproved(yamlPath: record.yamlPath)
    }

    /// Drop the record from the registry without persisting any
    /// approval. The YAML's service won't appear in the picker.
    func deny(record: DefinitionRecord) {
        definitionRegistry.remove(yamlPath: record.yamlPath)
    }

    // MARK: - Brew

    func refreshBrewStatus() async {
        brewCheck = .checking
        let status = await detector.detect()
        brewCheck = .ready(status)
    }

    // MARK: - Tailscale

    /// Detect which Tailscale flavour is present. Called once at launch
    /// and again after this app installs the open-source formula, so
    /// the pane flips from its install button to the installed state.
    func refreshTailscaleStatus() async {
        tailscaleCheck = .checking
        tailscaleCheck = .ready(await tailscaleDetector.detect())
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

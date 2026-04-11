import Foundation
import Observation

/// Observable app-wide state. Owns the BrewDetector and its most
/// recent result, plus the currently selected sidebar item.
@Observable
@MainActor
final class AppState {
    enum BrewCheckState: Equatable {
        case idle
        case checking
        case ready(BrewDetector.Status)
    }

    var brewCheck: BrewCheckState = .idle
    var selection: CatalogItem.ID?

    private let detector: BrewDetector

    init(detector: BrewDetector = BrewDetector()) {
        self.detector = detector
    }

    func refreshBrewStatus() async {
        brewCheck = .checking
        let status = await detector.detect()
        brewCheck = .ready(status)
    }
}

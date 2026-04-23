import Foundation
import Observation

/// Persistent user-preference store for Steading. One instance owns the
/// whole surface; views bind to it directly. Backed by `UserDefaults`
/// — the default instance uses `.standard`, and tests supply a scratch
/// suite via the initializer boundary.
///
/// The interval value is clamped on every write so a corrupt plist or
/// a mistaken `defaults write` cannot push Steading into a nonsensical
/// cadence. The pure `clampIntervalHours(_:)` entry point is exposed
/// for direct testing.
@Observable
@MainActor
final class PreferencesStore {

    enum Key {
        static let checkIntervalHours = "checkIntervalHours"
        static let checkOnLaunch      = "checkOnLaunch"
        static let notifyDockBadge    = "notifyDockBadge"
        static let notifyMenuBarLabel = "notifyMenuBarLabel"
        static let notifySystemBanner = "notifySystemBanner"
        static let lastCheckAt        = "lastCheckAt"
    }

    static let defaultCheckIntervalHours = 24
    static let minCheckIntervalHours     = 1
    static let maxCheckIntervalHours     = 168

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.checkIntervalHours: Self.defaultCheckIntervalHours,
            Key.checkOnLaunch:      true,
            Key.notifyDockBadge:    true,
            Key.notifyMenuBarLabel: true,
            Key.notifySystemBanner: true,
        ])
    }

    var checkIntervalHours: Int {
        get { defaults.integer(forKey: Key.checkIntervalHours) }
        set { defaults.set(Self.clampIntervalHours(newValue), forKey: Key.checkIntervalHours) }
    }

    var checkOnLaunch: Bool {
        get { defaults.bool(forKey: Key.checkOnLaunch) }
        set { defaults.set(newValue, forKey: Key.checkOnLaunch) }
    }

    var notifyDockBadge: Bool {
        get { defaults.bool(forKey: Key.notifyDockBadge) }
        set { defaults.set(newValue, forKey: Key.notifyDockBadge) }
    }

    var notifyMenuBarLabel: Bool {
        get { defaults.bool(forKey: Key.notifyMenuBarLabel) }
        set { defaults.set(newValue, forKey: Key.notifyMenuBarLabel) }
    }

    var notifySystemBanner: Bool {
        get { defaults.bool(forKey: Key.notifySystemBanner) }
        set { defaults.set(newValue, forKey: Key.notifySystemBanner) }
    }

    var lastCheckAt: Date? {
        get { defaults.object(forKey: Key.lastCheckAt) as? Date }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.lastCheckAt)
            } else {
                defaults.removeObject(forKey: Key.lastCheckAt)
            }
        }
    }

    /// Clamp a raw interval-hours value into the supported
    /// `[minCheckIntervalHours, maxCheckIntervalHours]` range. Pure.
    static func clampIntervalHours(_ value: Int) -> Int {
        min(max(value, minCheckIntervalHours), maxCheckIntervalHours)
    }
}

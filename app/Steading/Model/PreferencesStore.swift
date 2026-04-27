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

    // The properties below are computed against `defaults`, so the
    // `@Observable` macro can't auto-track them. Manual
    // `access(keyPath:)` / `withMutation(keyPath:)` calls are what
    // tell SwiftUI to re-evaluate any view bound to them — without
    // these the controls in PreferencesView appear read-only.

    var checkIntervalHours: Int {
        get {
            access(keyPath: \.checkIntervalHours)
            return defaults.integer(forKey: Key.checkIntervalHours)
        }
        set {
            withMutation(keyPath: \.checkIntervalHours) {
                defaults.set(Self.clampIntervalHours(newValue), forKey: Key.checkIntervalHours)
            }
        }
    }

    var checkOnLaunch: Bool {
        get {
            access(keyPath: \.checkOnLaunch)
            return defaults.bool(forKey: Key.checkOnLaunch)
        }
        set {
            withMutation(keyPath: \.checkOnLaunch) {
                defaults.set(newValue, forKey: Key.checkOnLaunch)
            }
        }
    }

    var notifyDockBadge: Bool {
        get {
            access(keyPath: \.notifyDockBadge)
            return defaults.bool(forKey: Key.notifyDockBadge)
        }
        set {
            withMutation(keyPath: \.notifyDockBadge) {
                defaults.set(newValue, forKey: Key.notifyDockBadge)
            }
        }
    }

    var notifyMenuBarLabel: Bool {
        get {
            access(keyPath: \.notifyMenuBarLabel)
            return defaults.bool(forKey: Key.notifyMenuBarLabel)
        }
        set {
            withMutation(keyPath: \.notifyMenuBarLabel) {
                defaults.set(newValue, forKey: Key.notifyMenuBarLabel)
            }
        }
    }

    var notifySystemBanner: Bool {
        get {
            access(keyPath: \.notifySystemBanner)
            return defaults.bool(forKey: Key.notifySystemBanner)
        }
        set {
            withMutation(keyPath: \.notifySystemBanner) {
                defaults.set(newValue, forKey: Key.notifySystemBanner)
            }
        }
    }

    var lastCheckAt: Date? {
        get {
            access(keyPath: \.lastCheckAt)
            return defaults.object(forKey: Key.lastCheckAt) as? Date
        }
        set {
            withMutation(keyPath: \.lastCheckAt) {
                if let newValue {
                    defaults.set(newValue, forKey: Key.lastCheckAt)
                } else {
                    defaults.removeObject(forKey: Key.lastCheckAt)
                }
            }
        }
    }

    /// Clamp a raw interval-hours value into the supported
    /// `[minCheckIntervalHours, maxCheckIntervalHours]` range. Pure.
    static func clampIntervalHours(_ value: Int) -> Int {
        min(max(value, minCheckIntervalHours), maxCheckIntervalHours)
    }
}

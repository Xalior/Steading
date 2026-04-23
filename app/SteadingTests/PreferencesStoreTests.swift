import Testing
import Foundation
@testable import Steading

/// Exercises the real `PreferencesStore` against an isolated scratch
/// `UserDefaults` suite. No mocks, no parallel reimplementations — the
/// production code path writes and reads the suite through the real
/// Foundation API, per CLAUDE.md's "tests ALWAYS exercise production
/// code" rule. The boundary input here is the suite name.
@Suite("PreferencesStore")
@MainActor
struct PreferencesStoreTests {

    /// Produce a clean `(defaults, suiteName)` pair and ensure the
    /// suite starts empty — a previous run may have left residue if it
    /// crashed before `removePersistentDomain`.
    private func makeScratchSuite() -> (UserDefaults, String) {
        let suite = "com.xalior.Steading.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private func teardown(_ suite: String) {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    // MARK: - Defaults

    @Test("defaults: every key returns its documented default on a fresh store")
    func fresh_defaults_match_table() {
        let (defaults, suite) = makeScratchSuite()
        defer { teardown(suite) }

        let prefs = PreferencesStore(defaults: defaults)

        #expect(prefs.checkIntervalHours  == 24)
        #expect(prefs.checkOnLaunch       == true)
        #expect(prefs.notifyDockBadge     == true)
        #expect(prefs.notifyMenuBarLabel  == true)
        #expect(prefs.notifySystemBanner  == true)
        #expect(prefs.lastCheckAt         == nil)
    }

    // MARK: - Interval clamping

    @Test("interval clamp: writing 0 clamps up to 1")
    func interval_clamp_low() {
        let (defaults, suite) = makeScratchSuite()
        defer { teardown(suite) }

        let prefs = PreferencesStore(defaults: defaults)
        prefs.checkIntervalHours = 0
        #expect(prefs.checkIntervalHours == 1)
    }

    @Test("interval clamp: writing 169 clamps down to 168")
    func interval_clamp_high() {
        let (defaults, suite) = makeScratchSuite()
        defer { teardown(suite) }

        let prefs = PreferencesStore(defaults: defaults)
        prefs.checkIntervalHours = 169
        #expect(prefs.checkIntervalHours == 168)
    }

    @Test("interval clamp: in-range values pass through unchanged")
    func interval_clamp_inrange() {
        let (defaults, suite) = makeScratchSuite()
        defer { teardown(suite) }

        let prefs = PreferencesStore(defaults: defaults)
        for value in [1, 2, 24, 72, 168] {
            prefs.checkIntervalHours = value
            #expect(prefs.checkIntervalHours == value)
        }
    }

    @Test("pure clamp function: boundary table")
    func pure_clamp_table() {
        #expect(PreferencesStore.clampIntervalHours(-1000) == 1)
        #expect(PreferencesStore.clampIntervalHours(0)     == 1)
        #expect(PreferencesStore.clampIntervalHours(1)     == 1)
        #expect(PreferencesStore.clampIntervalHours(24)    == 24)
        #expect(PreferencesStore.clampIntervalHours(168)   == 168)
        #expect(PreferencesStore.clampIntervalHours(169)   == 168)
        #expect(PreferencesStore.clampIntervalHours(999_999) == 168)
    }

    // MARK: - Round-trip for every key

    @Test("round-trip: checkIntervalHours persists")
    func roundtrip_interval() {
        let (defaults, suite) = makeScratchSuite()
        defer { teardown(suite) }

        do {
            let prefs = PreferencesStore(defaults: defaults)
            prefs.checkIntervalHours = 48
        }
        let reopened = PreferencesStore(defaults: defaults)
        #expect(reopened.checkIntervalHours == 48)
    }

    @Test("round-trip: every bool key persists its flipped value")
    func roundtrip_bools() {
        let (defaults, suite) = makeScratchSuite()
        defer { teardown(suite) }

        do {
            let prefs = PreferencesStore(defaults: defaults)
            prefs.checkOnLaunch      = false
            prefs.notifyDockBadge    = false
            prefs.notifyMenuBarLabel = false
            prefs.notifySystemBanner = false
        }
        let reopened = PreferencesStore(defaults: defaults)
        #expect(reopened.checkOnLaunch      == false)
        #expect(reopened.notifyDockBadge    == false)
        #expect(reopened.notifyMenuBarLabel == false)
        #expect(reopened.notifySystemBanner == false)
    }

    @Test("round-trip: lastCheckAt persists a Date, and nil is writable")
    func roundtrip_lastCheckAt() {
        let (defaults, suite) = makeScratchSuite()
        defer { teardown(suite) }

        let stamp = Date(timeIntervalSince1970: 1_700_000_000)

        do {
            let prefs = PreferencesStore(defaults: defaults)
            prefs.lastCheckAt = stamp
        }
        do {
            let reopened = PreferencesStore(defaults: defaults)
            #expect(reopened.lastCheckAt == stamp)
            reopened.lastCheckAt = nil
        }
        let reopened2 = PreferencesStore(defaults: defaults)
        #expect(reopened2.lastCheckAt == nil)
    }
}

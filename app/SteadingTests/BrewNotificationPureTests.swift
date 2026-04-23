import Testing
import Foundation
@testable import Steading

/// Pure-function coverage for the dock badge, menu-bar label, and
/// system-banner decision logic. Exercises the real production static
/// methods directly.
@Suite("Brew notifications — pure")
struct BrewNotificationPureTests {

    // MARK: - dockBadgeLabel

    @Test("dockBadgeLabel: disabled returns nil regardless of count")
    func dock_disabled() {
        #expect(BrewUpdateManager.dockBadgeLabel(count: 0, enabled: false) == nil)
        #expect(BrewUpdateManager.dockBadgeLabel(count: 7, enabled: false) == nil)
    }

    @Test("dockBadgeLabel: enabled but zero count returns nil")
    func dock_enabled_zero() {
        #expect(BrewUpdateManager.dockBadgeLabel(count: 0, enabled: true) == nil)
    }

    @Test("dockBadgeLabel: enabled non-zero returns the integer rendered")
    func dock_enabled_nonzero() {
        #expect(BrewUpdateManager.dockBadgeLabel(count: 1, enabled: true) == "1")
        #expect(BrewUpdateManager.dockBadgeLabel(count: 7, enabled: true) == "7")
        #expect(BrewUpdateManager.dockBadgeLabel(count: 42, enabled: true) == "42")
    }

    // MARK: - menuBarShowsCount

    @Test("menuBarShowsCount: only true when enabled AND count > 0")
    func menuBarShowsCount_table() {
        #expect(BrewUpdateManager.menuBarShowsCount(count: 0, enabled: true) == false)
        #expect(BrewUpdateManager.menuBarShowsCount(count: 1, enabled: false) == false)
        #expect(BrewUpdateManager.menuBarShowsCount(count: 0, enabled: false) == false)
        #expect(BrewUpdateManager.menuBarShowsCount(count: 1, enabled: true) == true)
        #expect(BrewUpdateManager.menuBarShowsCount(count: 99, enabled: true) == true)
    }

    // MARK: - bannerActionOnSettle

    @Test("bannerActionOnSettle: disabled → always noop")
    func banner_settle_disabled() {
        #expect(BrewUpdateManager.bannerActionOnSettle(previousCount: 0, newCount: 0, enabled: false) == .noop)
        #expect(BrewUpdateManager.bannerActionOnSettle(previousCount: 0, newCount: 5, enabled: false) == .noop)
        #expect(BrewUpdateManager.bannerActionOnSettle(previousCount: 5, newCount: 0, enabled: false) == .noop)
    }

    @Test("bannerActionOnSettle: enabled, newCount > 0 → post")
    func banner_settle_post() {
        #expect(BrewUpdateManager.bannerActionOnSettle(previousCount: 0, newCount: 3, enabled: true) == .post(count: 3))
        #expect(BrewUpdateManager.bannerActionOnSettle(previousCount: 7, newCount: 5, enabled: true) == .post(count: 5))
    }

    @Test("bannerActionOnSettle: enabled, count 0 after previous > 0 → removeDelivered")
    func banner_settle_drop_to_zero() {
        #expect(BrewUpdateManager.bannerActionOnSettle(previousCount: 5, newCount: 0, enabled: true) == .removeDelivered)
    }

    @Test("bannerActionOnSettle: enabled, count stays 0 → noop")
    func banner_settle_zero_to_zero() {
        #expect(BrewUpdateManager.bannerActionOnSettle(previousCount: 0, newCount: 0, enabled: true) == .noop)
    }

    // MARK: - bannerActionOnPrefChange

    @Test("bannerActionOnPrefChange: on → off → removeDelivered; off → on → noop")
    func banner_pref_change() {
        #expect(BrewUpdateManager.bannerActionOnPrefChange(wasEnabled: true, isEnabled: false)
                == .removeDelivered)
        #expect(BrewUpdateManager.bannerActionOnPrefChange(wasEnabled: false, isEnabled: true)
                == .noop)
        // No-change transitions are noop.
        #expect(BrewUpdateManager.bannerActionOnPrefChange(wasEnabled: true, isEnabled: true)
                == .noop)
        #expect(BrewUpdateManager.bannerActionOnPrefChange(wasEnabled: false, isEnabled: false)
                == .noop)
    }
}

import Testing
import Foundation
@testable import Steading

/// Pure-function coverage for the scheduler and retry back-off. Tests
/// call the production static methods directly with canned inputs.
@Suite("BrewUpdateSchedule")
struct BrewUpdateScheduleTests {

    // MARK: - shouldFireOnStartup

    private let oneDay: TimeInterval = 24 * 60 * 60
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("checkOnLaunch=true fires immediately regardless of lastCheckAt")
    func checkOnLaunch_always_fires() {
        #expect(BrewUpdateManager.shouldFireOnStartup(
            lastCheckAt: nil, interval: oneDay,
            checkOnLaunch: true, now: now
        ) == .fireNow)

        #expect(BrewUpdateManager.shouldFireOnStartup(
            lastCheckAt: now, interval: oneDay,
            checkOnLaunch: true, now: now
        ) == .fireNow)
    }

    @Test("checkOnLaunch=false and no prior check fires immediately")
    func no_prior_check_fires() {
        #expect(BrewUpdateManager.shouldFireOnStartup(
            lastCheckAt: nil, interval: oneDay,
            checkOnLaunch: false, now: now
        ) == .fireNow)
    }

    @Test("checkOnLaunch=false and overdue lastCheckAt fires immediately")
    func overdue_fires() {
        let stale = now.addingTimeInterval(-oneDay * 2)
        #expect(BrewUpdateManager.shouldFireOnStartup(
            lastCheckAt: stale, interval: oneDay,
            checkOnLaunch: false, now: now
        ) == .fireNow)
    }

    @Test("checkOnLaunch=false and exactly-due lastCheckAt fires immediately")
    func exactly_due_fires() {
        let exactly = now.addingTimeInterval(-oneDay)
        #expect(BrewUpdateManager.shouldFireOnStartup(
            lastCheckAt: exactly, interval: oneDay,
            checkOnLaunch: false, now: now
        ) == .fireNow)
    }

    @Test("checkOnLaunch=false and recent lastCheckAt schedules a wait")
    func recent_waits() {
        let halfAgo = now.addingTimeInterval(-oneDay / 2)
        let decision = BrewUpdateManager.shouldFireOnStartup(
            lastCheckAt: halfAgo, interval: oneDay,
            checkOnLaunch: false, now: now
        )
        guard case let .waitThenFire(delay) = decision else {
            Issue.record("expected waitThenFire, got \(decision)")
            return
        }
        #expect(abs(delay - oneDay / 2) < 0.001)
    }

    // MARK: - nextRetryDelay

    @Test("nextRetryDelay: curve for attempts 1…6")
    func back_off_curve() {
        #expect(BrewUpdateManager.nextRetryDelay(attempt: 1) == .seconds(60))
        #expect(BrewUpdateManager.nextRetryDelay(attempt: 2) == .seconds(120))
        #expect(BrewUpdateManager.nextRetryDelay(attempt: 3) == .seconds(240))
        #expect(BrewUpdateManager.nextRetryDelay(attempt: 4) == .seconds(480))
        #expect(BrewUpdateManager.nextRetryDelay(attempt: 5) == .seconds(900))
        #expect(BrewUpdateManager.nextRetryDelay(attempt: 6) == nil)
        #expect(BrewUpdateManager.nextRetryDelay(attempt: 99) == nil)
    }

    @Test("nextRetryDelay: zero or negative attempt is nil")
    func back_off_nonpositive() {
        #expect(BrewUpdateManager.nextRetryDelay(attempt: 0) == nil)
        #expect(BrewUpdateManager.nextRetryDelay(attempt: -1) == nil)
    }
}

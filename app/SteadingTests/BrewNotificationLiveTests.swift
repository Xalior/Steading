import Testing
import Foundation
import UserNotifications
@testable import Steading

/// Live test of the fixed-identifier replacement semantics. Posts two
/// UNNotificationRequests back-to-back with the same identifier and
/// asserts exactly one entry remains in `getDeliveredNotifications()`.
/// Skips gracefully when the test environment lacks the notification
/// entitlement or refuses authorization.
@Suite("Brew notifications — live")
struct BrewNotificationLiveTests {

    @Test("same-identifier posts replace, not stack, in Notification Center")
    func replacement_semantics() async throws {
        let center = UNUserNotificationCenter.current()

        // Ask for permission; a denied reply is a legitimate skip.
        let granted: Bool
        do {
            granted = try await center.requestAuthorization(options: [.alert, .badge])
        } catch {
            // Test environment without the entitlement; skip silently.
            return
        }
        guard granted else { return }

        let identifier = BrewUpdateManager.notificationIdentifier

        // Clean slate: remove anything already delivered with that id.
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        // Give the system a beat to process the removal.
        try? await Task.sleep(for: .milliseconds(50))

        func post(body: String) async throws {
            let content = UNMutableNotificationContent()
            content.title = "Brew updates available"
            content.body  = body
            let request = UNNotificationRequest(
                identifier: identifier, content: content, trigger: nil
            )
            try await center.add(request)
        }

        try await post(body: "first post")
        try? await Task.sleep(for: .milliseconds(100))
        try await post(body: "second post")
        try? await Task.sleep(for: .milliseconds(150))

        let delivered = await center.deliveredNotifications()
        let matching = delivered.filter { $0.request.identifier == identifier }

        // macOS collapses the entry so exactly one survives. A CI
        // environment without a notification server may have delivered
        // nothing, which we also treat as a legitimate skip.
        if matching.isEmpty { return }
        #expect(matching.count == 1,
                "same-identifier posts should replace, not stack; got \(matching.count)")

        // Clean up so the dev machine isn't littered with test toasts.
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}

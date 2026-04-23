import AppKit
import UserNotifications

/// Handles the bits of app lifecycle that SwiftUI's Scene graph
/// doesn't quite reach — reopening the main window on dock click,
/// terminate-deferral during an Apply, and routing a tap on a brew
/// notification to the Brew Package Manager window.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Set by the root view on appear. Calls `openWindow(id: "main")`
    /// from the SwiftUI environment so the Window scene recreates the
    /// NSWindow if it was closed.
    var openMainWindow: (() -> Void)?

    /// Set by the root view on appear — opens the Brew Package
    /// Manager window. Called from the notification-tap path.
    var openBrewPackageManager: (() -> Void)?

    /// Injected by the root view so the terminate handler can ask
    /// the brew-updater whether an upgrade is mid-flight.
    var isApplyInFlight: (() -> Bool)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .badge]) { _, _ in }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isApplyInFlight?() == true {
            NotificationCenter.default.post(name: .steadingAppQuitDuringApply, object: nil)
            return .terminateLater
        }
        return .terminateNow
    }

    func showWindow() {
        openMainWindow?()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier == BrewUpdateManager.notificationIdentifier {
            DispatchQueue.main.async {
                self.openBrewPackageManager?()
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Allow our banner to display even if Steading is frontmost.
        completionHandler([.banner, .list])
    }
}

import AppKit

/// Handles the bits of app lifecycle that SwiftUI's Scene graph
/// doesn't quite reach — most importantly, reopening the main window
/// when the user clicks the dock icon after closing it.
///
/// The `openMainWindow` closure is injected by the root SwiftUI view
/// on appear; it captures SwiftUI's `openWindow(id: "main")` action
/// so we can recreate the window after the user closes it with the
/// red button (which destroys the NSWindow entirely, unlike hide).
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Set by the root view on appear. Calls `openWindow(id: "main")`
    /// from the SwiftUI environment so the Window scene recreates the
    /// NSWindow if it was closed.
    var openMainWindow: (() -> Void)?

    /// Injected by the root view so the terminate handler can ask
    /// the brew-updater whether an upgrade is mid-flight. Returns
    /// `true` iff the user should be warned before quitting.
    var isApplyInFlight: (() -> Bool)?

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
}

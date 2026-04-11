import AppKit

/// Handles the bits of app lifecycle that SwiftUI's Scene graph
/// doesn't quite reach — most importantly, reopening the main window
/// when the user clicks the dock icon after closing it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    /// Keep the app alive after the last window closes — the menu bar
    /// icon is still around and clicking the dock icon should bring
    /// the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func showWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = findOrCacheMainWindow() {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func findOrCacheMainWindow() -> NSWindow? {
        if let w = mainWindow, NSApplication.shared.windows.contains(w) {
            return w
        }
        mainWindow = NSApplication.shared.windows.first(where: { $0.canBecomeMain })
        return mainWindow
    }
}

import SwiftUI
import AppKit

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o", modifiers: .command)

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

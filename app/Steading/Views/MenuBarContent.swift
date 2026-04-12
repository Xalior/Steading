import SwiftUI
import AppKit

struct MenuBarContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "house.fill")
                    .foregroundStyle(.tint)
                Text("Steading")
                    .font(.headline)
                Spacer()
            }

            Divider()

            Button {
                if let delegate = NSApp.delegate as? AppDelegate {
                    delegate.showWindow()
                }
            } label: {
                Label("Open Steading…", systemImage: "macwindow")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit Steading", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.plain)
        .padding(14)
        .frame(width: 240)
    }
}

import SwiftUI
import AppKit

struct MenuBarContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "house.fill")
                    .foregroundStyle(.tint)
                    .font(.title3)
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
                Label("Open", systemImage: "macwindow")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.plain)
        .padding()
        .frame(width: 220)
    }
}

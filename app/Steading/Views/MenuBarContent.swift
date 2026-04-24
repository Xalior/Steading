import SwiftUI
import AppKit

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

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
                dismiss()
                openWindow(id: "main")
            } label: {
                Label("Open", systemImage: "macwindow")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.plain)
        .padding()
        .frame(width: 220)
    }
}

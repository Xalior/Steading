import SwiftUI
import AppKit

struct MenuBarContent: View {
    @Environment(AppState.self) private var appState

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

            BrewStatusBadge(state: appState.brewCheck)
                .frame(maxWidth: .infinity, alignment: .leading)

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

            Button {
                Task { await appState.refreshBrewStatus() }
            } label: {
                Label("Check for Homebrew", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(appState.brewCheck == .checking)

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
        .frame(width: 300)
    }
}

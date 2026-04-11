import SwiftUI

@main
struct SteadingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        Window("Steading", id: "main") {
            Group {
                if appState.isReady {
                    ContentView()
                } else {
                    OnboardingView()
                }
            }
            .environment(appState)
            .task {
                await appState.refreshBrewStatus()
                appState.refreshHelperStatus()
            }
            .frame(minWidth: 860, minHeight: 560)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("Check for Homebrew") {
                    Task { await appState.refreshBrewStatus() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        MenuBarExtra("Steading", systemImage: "house.fill") {
            MenuBarContent()
                .environment(appState)
        }
        .menuBarExtraStyle(.window)
    }
}

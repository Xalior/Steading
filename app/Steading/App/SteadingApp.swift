import SwiftUI

@main
struct SteadingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()
    @State private var preferences = PreferencesStore()

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
            .environment(preferences)
            .background(WindowBridge(appDelegate: appDelegate))
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
            CommandMenu("Tools") {
                ToolsMenuContent()
            }
        }

        Settings {
            PreferencesView()
                .environment(preferences)
        }

        Window("Edit /etc/hosts", id: "hosts-editor") {
            HostsEditorView()
                .environment(appState)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 720, height: 520)

        MenuBarExtra("Steading", systemImage: "house.fill") {
            MenuBarContent()
                .environment(appState)
                .environment(preferences)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Body of the main menu bar's **Tools** menu. Split out so the `@Environment`
/// openWindow action is available (it isn't inside the `.commands` modifier's
/// builder directly).
private struct ToolsMenuContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Edit /etc/hosts…") {
            openWindow(id: "hosts-editor")
        }
    }
}

/// Invisible bridge that captures SwiftUI's `openWindow` environment
/// action and hands it to the AppDelegate so the dock-click reopen
/// path (`applicationShouldHandleReopen`) can recreate the Window
/// scene after the user closes it with the red button.
private struct WindowBridge: View {
    @Environment(\.openWindow) private var openWindow
    let appDelegate: AppDelegate

    var body: some View {
        Color.clear.onAppear {
            appDelegate.openMainWindow = { [openWindow] in
                openWindow(id: "main")
            }
        }
    }
}

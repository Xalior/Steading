import SwiftUI

@main
struct SteadingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()
    @State private var preferences: PreferencesStore
    @State private var brewUpdates: BrewUpdateManager
    @State private var brewPackages: BrewPackageManager
    @State private var askpassService = AskpassService()

    init() {
        let prefs = PreferencesStore()
        _preferences = State(initialValue: prefs)
        _brewUpdates = State(initialValue: BrewUpdateManager(preferences: prefs))
        _brewPackages = State(initialValue: BrewPackageManager())
    }

    var body: some Scene {
        Window("Steading", id: "main") {
            Group {
                if !appState.isReady {
                    OnboardingView()
                } else if !appState.definitionRegistry.pendingApprovals.isEmpty {
                    ServiceDefinitionApprovalSheet()
                } else {
                    ContentView()
                }
            }
            // Inner of the .environment calls so the presenter's
            // @Environment(BrewPackageManager/AskpassService) resolve
            // (environment flows outer → inner).
            .brewApplyModal(for: BrewPackageManager.mainWindowID)
            .environment(appState)
            .environment(preferences)
            .environment(brewUpdates)
            .environment(brewPackages)
            .environment(askpassService)
            .background(WindowBridge(appDelegate: appDelegate))
            .background(NotificationSurfaceController()
                .environment(brewUpdates)
                .environment(preferences))
            .task {
                await appState.refreshBrewStatus()
                appState.refreshHelperStatus()
                // One-shot Tailscale detection. The result is cached for
                // the session — see AppState.tailscaleCheck.
                await appState.refreshTailscaleStatus()
                appDelegate.isApplyInFlight = { brewPackages.state == .applying }
                askpassService.start()
                brewUpdates.start()
                // Warm the package universe at launch so the multi-second
                // internal-index parse is done before the Brew Package
                // Manager window is ever opened. `refresh` is fire-and-
                // forget (parse runs detached off the main actor) and
                // `brewPackages` outlives every window open/close, so the
                // window's own `.task(id:)` reload finds rows already warm
                // and overlays its spinner instead of blanking.
                brewPackages.refresh(outdated: brewUpdates.outdated)
                if appState.isReady {
                    await appState.loadDefinitionRegistry()
                }
            }
            .task(id: appState.isReady) {
                if appState.isReady {
                    await appState.loadDefinitionRegistry()
                }
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

        Window("Brew Package Manager", id: "brew-package-manager") {
            BrewPackageManagerView()
                .brewApplyModal(for: BrewPackageManager.packageManagerWindowID)
                .environment(brewUpdates)
                .environment(brewPackages)
                .environment(askpassService)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1100, height: 640)
        // The Tools menu already exposes this window; suppress the
        // automatic Window-menu entry SwiftUI would otherwise add
        // for the scene so the menu bar isn't duplicated.
        .commandsRemoved()

        Window("Edit /etc/hosts", id: "hosts-editor") {
            HostsEditorView()
                .environment(appState)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 720, height: 520)
        .commandsRemoved()

        MenuBarExtra {
            MenuBarContent()
                .environment(appState)
                .environment(preferences)
        } label: {
            MenuBarLabel()
                .environment(brewUpdates)
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
        Button("Brew Package Manager…") {
            openWindow(id: "brew-package-manager")
        }
        Divider()
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
            appDelegate.openBrewPackageManager = { [openWindow] in
                openWindow(id: "brew-package-manager")
            }
        }
    }
}

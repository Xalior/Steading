import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        NavigationSplitView {
            SidebarView(selection: $state.selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            detailView
        }
        .navigationTitle("Steading")
        .toolbar {
            ToolbarItem(placement: .principal) {
                BrewStatusBadge(state: appState.brewCheck)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await appState.refreshBrewStatus() }
                } label: {
                    Label("Check for Homebrew", systemImage: "arrow.clockwise")
                }
                .disabled(appState.brewCheck == .checking)
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if let id = appState.selection, let item = Self.allItems.first(where: { $0.id == id }) {
            switch item.kind {
            case .builtIn:
                if let runner = BuiltInServiceRegistry.runner(for: item.id) {
                    BuiltInServiceDetailView(item: item, runner: runner)
                } else {
                    CatalogDetailView(item: item)
                }
            case .service, .webapp:
                CatalogDetailView(item: item)
            }
        } else {
            WelcomeView()
        }
    }

    private static let allItems: [CatalogItem] =
        ServiceCatalog.items + WebappCatalog.items + BuiltInCatalog.items
}

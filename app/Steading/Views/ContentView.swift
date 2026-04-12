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
    }

    @ViewBuilder
    private var detailView: some View {
        // Treat both `nil` and the Dashboard sentinel as "show the
        // dashboard". Any real catalog id routes to its detail view.
        if let id = appState.selection,
           id != CatalogItem.dashboardTag,
           let item = Self.allItems.first(where: { $0.id == id }) {
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
            DashboardView()
        }
    }

    private static let allItems: [CatalogItem] =
        ServiceCatalog.items + WebappCatalog.items + BuiltInCatalog.items
}

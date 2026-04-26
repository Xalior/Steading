import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        let isDetail = state.selection != nil
            && state.selection != CatalogItem.dashboardTag

        NavigationSplitView {
            SidebarView(selection: $state.selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            detailView(for: state.selection)
                .id(state.selection ?? CatalogItem.dashboardTag)
                .toolbar {
                    if isDetail {
                        ToolbarItem(placement: .navigation) {
                            Button {
                                state.selection = CatalogItem.dashboardTag
                            } label: {
                                Label("Dashboard", systemImage: "chevron.left")
                            }
                            .help("Return to Dashboard")
                        }
                    }
                }
        }
        .navigationTitle("Steading")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomStatusStrip()
        }
    }

    @ViewBuilder
    private func detailView(for selection: CatalogItem.ID?) -> some View {
        // Both `nil` and the Dashboard sentinel route to DashboardView.
        // Any real catalog id routes to its detail view.
        if selection == nil || selection == CatalogItem.dashboardTag {
            DashboardView()
        } else if let id = selection,
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

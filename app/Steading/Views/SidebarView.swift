import SwiftUI

struct SidebarView: View {
    @Binding var selection: CatalogItem.ID?

    var body: some View {
        List(selection: $selection) {
            // Top-level Dashboard row — outside any section, native
            // macOS pattern for a "home" entry above categorised
            // content. Selects the sentinel tag which ContentView
            // routes to DashboardView.
            Label("Dashboard", systemImage: "square.grid.2x2")
                .tag(CatalogItem.dashboardTag as CatalogItem.ID?)

            Section("Services") {
                ForEach(ServiceCatalog.items) { item in
                    CatalogRow(item: item)
                }
            }
            Section("Webapps") {
                ForEach(WebappCatalog.items) { item in
                    CatalogRow(item: item)
                }
            }
            Section("macOS Built-ins") {
                ForEach(BuiltInCatalog.items) { item in
                    CatalogRow(item: item)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct CatalogRow: View {
    let item: CatalogItem

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.body)
                    if item.optional {
                        Text("optional")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(Color.secondary.opacity(0.15))
                            )
                    }
                }
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: item.symbol)
                .foregroundStyle(.tint)
        }
        .tag(item.id)
    }
}

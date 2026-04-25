import SwiftUI

/// Default detail pane when no sidebar item is selected. Shows a
/// live-status grid of all macOS built-in services — each card
/// queries its runner on appear, displays the current state as a
/// colored badge, and navigates to the full detail view on tap.
struct DashboardView: View {
    @Environment(AppState.self) private var appState
    @State private var serviceStates: [String: BuiltInServiceState] = [:]
    @State private var isLoading = true

    private let columns = [
        GridItem(.adaptive(minimum: 260, maximum: 380), spacing: 16)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if isLoading && serviceStates.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Checking services…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                } else {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(BuiltInCatalog.items) { item in
                            ServiceStatusCard(
                                item: item,
                                state: serviceStates[item.id] ?? .unknown(reason: ""),
                                onTap: { appState.selection = item.id }
                            )
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Re-fire whenever sidebar selection changes — specifically
        // fires again when the user navigates BACK to the dashboard,
        // so any Enable/Disable action that happened in a detail view
        // is reflected here on return. Both nil and the dashboard
        // sentinel route to this view via ContentView.
        .task(id: appState.selection) {
            let id = appState.selection
            guard id == nil || id == CatalogItem.dashboardTag else { return }
            await loadStates()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Services")
                .font(.largeTitle.weight(.semibold))
            Text("macOS built-in server facilities — live status")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Data

    private func loadStates() async {
        isLoading = true
        await withTaskGroup(of: (String, BuiltInServiceState).self) { group in
            for item in BuiltInCatalog.items {
                if let runner = BuiltInServiceRegistry.runner(for: item.id) {
                    group.addTask {
                        let state = await runner.readState()
                        return (item.id, state)
                    }
                }
            }
            for await (id, state) in group {
                serviceStates[id] = state
            }
        }
        isLoading = false
    }
}

// MARK: - Card

private struct ServiceStatusCard: View {
    let item: CatalogItem
    let state: BuiltInServiceState
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: item.symbol)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(tint)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(tint.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        stateChip
                    }

                    if let detail = detailLine {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospaced()
                            .lineLimit(1)
                    } else {
                        Text(item.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.quaternary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(backgroundFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(tint.opacity(isActive ? 0.6 : 0.2),
                            lineWidth: isActive ? 1 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Active highlighting

    /// Cards for services that are currently ON get a stronger tint
    /// on the background and border so the dashboard reads at a glance
    /// as "what's running here".
    private var isActive: Bool {
        switch state {
        case .enabled:                      return true
        case .custom(_, .some(true)):       return true
        default:                            return false
        }
    }

    private var backgroundFill: AnyShapeStyle {
        if isActive {
            AnyShapeStyle(tint.opacity(0.08).gradient)
        } else {
            AnyShapeStyle(.background.secondary)
        }
    }

    // MARK: - State chip

    private var stateChip: some View {
        Text(chipLabel)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(tint.opacity(0.12))
            )
    }

    private var chipLabel: String {
        switch state {
        case .enabled:                      return "on"
        case .disabled:                     return "off"
        case .custom(_, .some(true)):       return "on"
        case .custom(_, .some(false)):      return "off"
        case .custom(_, .none):             return "custom"
        case .unknown:                      return "—"
        case .error:                        return "error"
        }
    }

    // MARK: - Detail line

    /// Shows enriched detail when the runner provides it — e.g. the
    /// pmset summary for power management. Falls back to the catalog
    /// item's subtitle when the state is a simple boolean.
    private var detailLine: String? {
        switch state {
        case .custom(let summary, _):
            return summary
        case .error(let msg):
            return msg
        case .unknown(let reason) where !reason.isEmpty:
            return reason
        default:
            return nil
        }
    }

    // MARK: - Tint

    private var tint: Color {
        switch state {
        case .enabled:                      return .green
        case .disabled:                     return .secondary
        case .custom(_, .some(true)):       return .green
        case .custom(_, .some(false)):      return .secondary
        case .custom(_, .none):             return .accentColor
        case .unknown:                      return .secondary
        case .error:                        return .orange
        }
    }
}

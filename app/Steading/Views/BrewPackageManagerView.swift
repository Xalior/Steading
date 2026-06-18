import SwiftUI
import AppKit

/// Brew Package Manager window. Three-pane layout (sidebar / list /
/// details) bound to `BrewPackageManager` for the package universe,
/// marking, Apply pipeline, and pin/unpin verbs; reads from
/// `BrewUpdateManager` for the upgradable subset and the Check Now
/// invocation. Apply hands off to the shared `BrewApplyView` modal,
/// which owns the streaming output, the askpass prompt, the autoremove
/// confirmation, and the quit-while-applying guard for every brew job.
struct BrewPackageManagerView: View {

    @Environment(BrewUpdateManager.self) private var brewUpdates
    @Environment(BrewPackageManager.self) private var packages

    @State private var newTapText = ""
    /// The argv the user is being asked to confirm before Apply runs.
    /// Non-nil while the plan confirmation is up; lets hidden marks
    /// (e.g. a removal marked under a different filter) surface before
    /// anything destructive runs.
    @State private var applyPlan: BrewPackageManager.ApplyArgv?
    @State private var selectedRowID: String?
    @State private var sortOrder: [KeyPathComparator<BrewPackageManager.PackageRow>] = [
        KeyPathComparator(\.entry.token)
    ]
    /// Local typed-search text. Writes to `packages.searchText`
    /// happen on a debounced trailing edge so the per-keystroke
    /// re-filter (5k+ rows × substring match) doesn't stutter
    /// typing.
    @State private var typedSearch: String = ""
    @State private var searchDebounce: Task<Void, Never>?

    var body: some View {
        @Bindable var packages = packages

        coreLayout(packages: Bindable(packages))
            .toolbar { toolbarContents(packages: packages) }
            .searchable(text: $typedSearch, prompt: "Search packages")
            .onChange(of: typedSearch) { _, newValue in
                searchDebounce?.cancel()
                searchDebounce = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    packages.searchText = newValue
                    if !newValue.isEmpty {
                        packages.sidebarMode = .searchResults
                    }
                }
            }
            .task(id: brewUpdates.outdated) {
                packages.refresh(outdated: brewUpdates.outdated)
            }
            // An Apply changes what's installed / pinned / upgradable, so
            // the index is stale the moment it finishes. `recentApplyOutcome`
            // flips from nil to a terminal outcome on completion (any
            // outcome — a partial failure or cancel still mutated state).
            // Re-run `brew outdated` so the upgradable set is fresh — that
            // re-fires the `.task(id:)` above if it changed — and recompose
            // rows immediately so a plain install or removal (which leaves
            // `outdated` unchanged) still reflects the new installed set.
            .onChange(of: packages.recentApplyOutcome) { _, outcome in
                guard outcome != nil else { return }
                brewUpdates.check()
                packages.refresh(outdated: brewUpdates.outdated)
            }
            .confirmationDialog(
                "Apply these changes?",
                isPresented: Binding(
                    get: { applyPlan != nil },
                    set: { if !$0 { applyPlan = nil } }
                ),
                titleVisibility: .visible,
                presenting: applyPlan
            ) { plan in
                Button("Apply") {
                    packages.startApply(argv: plan,
                                        owner: BrewPackageManager.packageManagerWindowID)
                    applyPlan = nil
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) { applyPlan = nil }
            } message: { plan in
                Text(Self.planSummary(plan))
            }
    }

    /// Human-readable summary of a pending Apply, destructive verb
    /// first. Pure — exposed for tests.
    static func planSummary(_ argv: BrewPackageManager.ApplyArgv) -> String {
        var lines: [String] = []
        if !argv.removes.isEmpty {
            lines.append("Remove: " + argv.removes.joined(separator: ", "))
        }
        if !argv.upgrades.isEmpty {
            lines.append("Upgrade: " + argv.upgrades.joined(separator: ", "))
        }
        if !argv.installs.isEmpty {
            lines.append("Install: " + argv.installs.joined(separator: ", "))
        }
        return lines.isEmpty ? "No changes to apply." : lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func coreLayout(packages: Bindable<BrewPackageManager>) -> some View {
        HStack(spacing: 0) {
            // Fixed-width sidebar — the contents (mode buttons + the
            // mode-specific list) are short text rows that don't
            // benefit from being wider, and a draggable splitter on
            // a sidebar this narrow tended to be misadjusted into
            // either obscuring the buttons or eating into the table.
            sidebar(packages: packages)
                .frame(width: 180)

            Divider()

            // Centre column: the package table. The streaming-output
            // progress area is no longer inline here — every brew
            // mutation now surfaces through the shared `BrewApplyView`
            // modal (see `BrewPackageManager.startApply`).
            packageListPane(packages: packages.wrappedValue)
                .frame(minWidth: 380)

            Divider()

            // Fixed-width details pane — same rationale as the
            // sidebar: contents are bounded text-metadata rows so a
            // resizable split just lets it grow past what's useful.
            detailsPane(packages: packages.wrappedValue)
                .frame(width: 220)
        }
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 540, idealHeight: 640)
    }

    // MARK: - Sidebar

    @ViewBuilder
    private func sidebar(packages: Bindable<BrewPackageManager>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Mode-specific list takes the upper space, leaving the
            // three stacked mode buttons as a Synaptic-style bottom
            // rail.
            switch packages.wrappedValue.sidebarMode {
            case .status:
                statusModeList(packages: packages)
            case .origin:
                originModeList(packages: packages)
            case .searchResults:
                searchResultsHint(packages: packages.wrappedValue)
            }

            Divider()

            VStack(spacing: 4) {
                modeButton(
                    .status, label: "Status", icon: "checklist",
                    selection: packages.sidebarMode
                )
                modeButton(
                    .origin, label: "Origin", icon: "tray.full",
                    selection: packages.sidebarMode
                )
                modeButton(
                    .searchResults, label: "Search Results", icon: "magnifyingglass",
                    selection: packages.sidebarMode
                )
            }
            .padding(8)
        }
        .background(.thinMaterial)
    }

    /// One full-width mode-selector button. Shows icon + label, with
    /// a tinted background when the button's mode is the current
    /// selection. Plain button style + a manual selected highlight
    /// is more compact and label-friendly than `.segmented` at
    /// narrow widths.
    private func modeButton(_ mode: BrewPackageManager.SidebarMode,
                            label: String,
                            icon: String,
                            selection: Binding<BrewPackageManager.SidebarMode>) -> some View {
        let isSelected = selection.wrappedValue == mode
        return Button {
            selection.wrappedValue = mode
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
            )
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func statusModeList(packages: Bindable<BrewPackageManager>) -> some View {
        List(BrewPackageManager.StatusFilter.allCases, id: \.self,
             selection: packages.statusFilter) { filter in
            Text(filter.label)
                .lineLimit(1)
                .truncationMode(.tail)
                .tag(filter)
        }
        .listStyle(.plain)
    }

    private func originModeList(packages: Bindable<BrewPackageManager>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            List(packages.wrappedValue.taps, id: \.name,
                 selection: packages.originTap) { tap in
                HStack(spacing: 4) {
                    Text(tap.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if tap.name != "homebrew/core" && tap.name != "homebrew/cask" {
                        Button(role: .destructive) {
                            packages.wrappedValue.removeTap(tap.name,
                                                            outdated: brewUpdates.outdated)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .tag(tap.name)
            }
            .listStyle(.plain)

            Divider()

            HStack(spacing: 6) {
                TextField("user/repo", text: $newTapText)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    let trimmed = newTapText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    packages.wrappedValue.addTap(trimmed, outdated: brewUpdates.outdated)
                    newTapText = ""
                }
                .disabled(newTapText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(8)
        }
    }

    private func searchResultsHint(packages: BrewPackageManager) -> some View {
        VStack(spacing: 8) {
            if packages.searchText.isEmpty {
                Text("Type a search term in the toolbar to filter the package list by name and description.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            } else {
                Text("Showing matches for")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\u{201C}\(packages.searchText)\u{201D}")
                    .font(.body.weight(.semibold))
                Text("\(packages.filteredRows.count) result\(packages.filteredRows.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(8)
    }

    // MARK: - Package list

    @ViewBuilder
    private func packageListPane(packages: BrewPackageManager) -> some View {
        let displayed = packages.filteredRows.sorted(using: sortOrder)
        packageTable(displayed: displayed, packages: packages)
            .overlay {
                if packages.state == .loading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.4)
                        Text("Loading package index…")
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(.regularMaterial,
                                in: RoundedRectangle(cornerRadius: 12))
                }
            }
    }

    @ViewBuilder
    private func packageTable(displayed: [BrewPackageManager.PackageRow],
                              packages: BrewPackageManager) -> some View {
        Table(displayed, selection: $selectedRowID, sortOrder: $sortOrder) {
            TableColumn("✓") { row in
                Toggle(isOn: Binding(
                    get: { packages.marked.contains(row.id) },
                    set: { packages.mark(row.id, $0) }
                )) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .disabled(!buttonsState(packages: packages).perRowEnabled)
            }
            .width(28)

            TableColumn("Name", value: \.entry.token) { row in
                HStack(spacing: 6) {
                    Text(row.entry.token)
                    if row.isPinned {
                        Image(systemName: "pin.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }
            }

            TableColumn("Kind", value: \.entry.kind.rawValue) { row in
                Text(row.entry.kind == .formula ? "Formula" : "Cask")
                    .font(.caption)
                    .foregroundStyle(row.entry.kind == .formula ? .blue : .purple)
            }
            .width(60)

            TableColumn("Tap", value: \.entry.tap) { row in
                Text(row.entry.tap)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TableColumn("Status") { row in
                Text(rowStatusText(row))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .width(90)
        }
        .contextMenu(forSelectionType: String.self) { selection in
            if let id = selection.first,
               let row = packages.rows.first(where: { $0.id == id }),
               row.entry.kind == .formula,
               row.isInstalled {
                if row.isPinned {
                    Button("Unpin") { packages.unpin(row.entry.token) }
                } else {
                    Button("Pin") { packages.pin(row.entry.token) }
                }
            }
        }
    } // packageTable

    private func rowStatusText(_ row: BrewPackageManager.PackageRow) -> String {
        if !row.isInstalled { return "not installed" }
        if row.isOutdated { return "upgradable" }
        if row.isPinned { return "pinned" }
        return "installed"
    }

    // MARK: - Details pane

    @ViewBuilder
    private func detailsPane(packages: BrewPackageManager) -> some View {
        if let id = selectedRowID,
           let row = packages.rows.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 10) {
                Text(row.entry.token)
                    .font(.title3.weight(.semibold))

                Text(row.entry.fullToken)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Divider()

                row.entry.desc.map { desc in
                    Text(desc)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                LabeledContent("Tap") {
                    Text(row.entry.tap).foregroundStyle(.secondary)
                }
                LabeledContent("Kind") {
                    Text(row.entry.kind == .formula ? "Formula" : "Cask")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Installed") {
                    Text(row.isInstalled ? "Yes" : "No")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Pinned") {
                    Text(row.isPinned ? "Yes" : "No")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Upgradable") {
                    Text(row.isOutdated ? "Yes" : "No")
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack {
                Spacer()
                Text("Select a package")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func toolbarContents(packages: BrewPackageManager) -> some ToolbarContent {
        let buttons = buttonsState(packages: packages)
        let isChecking = brewUpdates.state == .checking

        ToolbarItem {
            Button("Mark All Upgrades") { packages.markAllUpgrades() }
                .disabled(!buttons.markAllEnabled)
        }
        ToolbarItem {
            // Always render the same Button shape so the toolbar
            // doesn't reflow when the headless cycle starts. Label
            // is pinned to a fixed width and swaps inner content
            // (spinner + "Checking…" vs. "Check Now").
            Button {
                brewUpdates.check()
            } label: {
                HStack(spacing: 6) {
                    if isChecking {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isChecking ? "Checking…" : "Check Now")
                }
                .frame(width: 100, alignment: .center)
            }
            .disabled(isChecking || !buttons.checkNowEnabled)
        }
        ToolbarItem {
            // Apply first raises a plan confirmation; confirming there
            // launches the job and the shared modal takes over with
            // progress, Cancel, and the outcome.
            Button("Apply") {
                applyPlan = BrewPackageManager.applyArgv(for: packages.markedRows)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!buttons.applyEnabled || isChecking)
        }
    }

    // MARK: - Buttons

    private func buttonsState(packages: BrewPackageManager) -> BrewPackageManager.Buttons {
        BrewPackageManager.buttons(
            state: packages.state,
            markedCount: packages.marked.count,
            upgradableCount: packages.upgradableCount
        )
    }

}

// MARK: - Sidebar / status filter labels

extension BrewPackageManager.StatusFilter {
    var label: String {
        switch self {
        case .installed:    return "installed"
        case .notInstalled: return "not installed"
        case .upgradable:   return "upgradable"
        case .pinned:       return "pinned"
        }
    }
}

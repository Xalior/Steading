import SwiftUI
import AppKit

/// Brew Package Manager window. Three-pane layout (sidebar / list /
/// details) bound to `BrewPackageManager` for the package universe,
/// marking, Apply pipeline, and pin/unpin verbs; reads from
/// `BrewUpdateManager` for the upgradable subset and the Check Now
/// invocation. The askpass sheet, the close-while-applying
/// confirmation, the post-uninstall autoremove confirmation, and the
/// streaming-output disclosure are all surfaced through the new
/// manager's state.
struct BrewPackageManagerView: View {

    @Environment(BrewUpdateManager.self) private var brewUpdates
    @Environment(BrewPackageManager.self) private var packages
    @Environment(AskpassService.self) private var askpass
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var detailsShown: Bool = false
    @State private var closeWarning: CloseReason?
    @State private var passwordInput = ""
    @State private var newTapText = ""
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

    enum CloseReason: Identifiable {
        case closeWindow
        case quitApp
        var id: Int { self == .closeWindow ? 0 : 1 }
    }

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
            .modifier(WindowChromeModifier(
                packages: packages,
                askpass: askpass,
                dismissWindow: dismissWindow,
                closeWarning: $closeWarning,
                passwordModal: passwordModal
            ))
            .onReceive(NotificationCenter.default.publisher(for: .steadingAppQuitDuringApply)) { _ in
                closeWarning = .quitApp
            }
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

            // Centre column: the package table on top with the
            // streaming-output progress area below it. Vertical
            // split stays resizable so the user can grow the log
            // area when an Apply is in flight.
            VSplitView {
                packageListPane(packages: packages.wrappedValue)
                    .frame(minHeight: 220)

                if shouldShowProgressArea {
                    progressArea
                        .frame(minHeight: 120)
                }
            }
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
            if buttons.cancelEnabled {
                Button("Cancel", role: .destructive) {
                    packages.cancelApply()
                    askpass.respondCancel()
                }
            } else {
                Button("Apply") { packages.apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!buttons.applyEnabled || isChecking)
            }
        }
    }

    // MARK: - Progress / streaming output

    private var shouldShowProgressArea: Bool {
        packages.state == .applying || packages.recentApplyOutcome != nil
    }

    @ViewBuilder
    private var progressArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if packages.state == .applying {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                } else if let outcome = packages.recentApplyOutcome {
                    outcomeIndicator(for: outcome)
                }
            }

            DisclosureGroup(isExpanded: $detailsShown) {
                ScrollView {
                    Text(packages.applyLog.isEmpty ? "(no output yet)" : packages.applyLog)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(height: 180)
                .background(Color(NSColor.textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3))
                )
            } label: {
                Text(detailsShown ? "Hide details" : "Show details")
                    .font(.caption)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func outcomeIndicator(for outcome: BrewPackageManager.ApplyOutcome) -> some View {
        switch outcome {
        case .success:
            Label("Pipeline complete.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let code):
            Label("brew exited \(code).", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .cancelled:
            Label("Pipeline canceled.", systemImage: "stop.circle.fill")
                .foregroundStyle(.orange)
        case .spawnFailed(let reason):
            Label("Could not start brew: \(reason)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
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

    // MARK: - Password modal

    private func submitPassword() {
        let value = passwordInput
        passwordInput = ""
        askpass.respond(password: value)
    }

    private func cancelPassword() {
        passwordInput = ""
        askpass.respondCancel()
    }

    @ViewBuilder
    private var passwordModal: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Administrator password required")
                .font(.headline)
            Text("brew is asking for an administrator password to finish the current sub-call. Your password is used once and not stored.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Password", text: $passwordInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submitPassword() }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { cancelPassword() }
                Button("Continue") { submitPassword() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(passwordInput.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

// MARK: - Window chrome modifier

/// Wraps the close-while-applying confirmation, the autoremove
/// confirmation, the askpass sheet, and the close-attempt
/// `CloseInterceptor` into a single `ViewModifier` so the main view
/// body stays inside the SwiftUI type-checker's tractability budget.
private struct WindowChromeModifier: ViewModifier {
    let packages: BrewPackageManager
    let askpass: AskpassService
    let dismissWindow: DismissWindowAction
    @Binding var closeWarning: BrewPackageManagerView.CloseReason?
    let passwordModal: AnyView

    init(packages: BrewPackageManager,
         askpass: AskpassService,
         dismissWindow: DismissWindowAction,
         closeWarning: Binding<BrewPackageManagerView.CloseReason?>,
         passwordModal: some View) {
        self.packages = packages
        self.askpass = askpass
        self.dismissWindow = dismissWindow
        self._closeWarning = closeWarning
        self.passwordModal = AnyView(passwordModal)
    }

    func body(content: Content) -> some View {
        content
            .background(CloseInterceptor(
                shouldWarn: { packages.state == .applying },
                onAttemptedClose: { closeWarning = .closeWindow }
            ))
            .confirmationDialog(
                "Cancel pipeline in progress?",
                isPresented: Binding(
                    get: { closeWarning != nil },
                    set: { if !$0 { closeWarning = nil } }
                ),
                titleVisibility: .visible,
                presenting: closeWarning
            ) { reason in
                Button("Keep Running", role: .cancel) { closeWarning = nil }
                Button("Cancel and Close Anyway", role: .destructive) {
                    packages.cancelApply()
                    askpass.respondCancel()
                    closeWarning = nil
                    switch reason {
                    case .closeWindow:
                        dismissWindow(id: "brew-package-manager")
                    case .quitApp:
                        NSApp.reply(toApplicationShouldTerminate: true)
                    }
                }
            } message: { _ in
                Text("Stopping mid-pipeline is equivalent to pressing Ctrl-C during a brew sub-call. Packages currently being installed or removed may be left in a partial or broken state, and your Homebrew installation may need manual repair.")
            }
            .confirmationDialog(
                "Run brew autoremove?",
                isPresented: Binding(
                    get: { packages.pendingAutoremoveConfirmation },
                    set: { if !$0 { packages.confirmAutoremove(false) } }
                ),
                titleVisibility: .visible
            ) {
                Button("Yes, autoremove unused dependencies") {
                    packages.confirmAutoremove(true)
                }
                .keyboardShortcut(.defaultAction)
                Button("No, leave them in place", role: .cancel) {
                    packages.confirmAutoremove(false)
                }
            } message: {
                Text("The uninstall step succeeded. Some of the formulae it depended on may now be unused. brew autoremove will sweep them up.")
            }
            .sheet(item: Binding(
                get: { askpass.pendingRequest },
                set: { new in
                    if new == nil, askpass.pendingRequest != nil {
                        askpass.respondCancel()
                    }
                }
            )) { _ in
                passwordModal
            }
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

// MARK: - Close interception

/// NSWindowDelegate bridge that routes the window's close gestures
/// (red button, Cmd+W) through a warning when a gate predicate is
/// true. Re-evaluated on every close attempt.
private struct CloseInterceptor: NSViewRepresentable {
    var shouldWarn: () -> Bool
    var onAttemptedClose: () -> Void

    final class Coordinator: NSObject, NSWindowDelegate {
        var shouldWarn: () -> Bool
        var onAttemptedClose: () -> Void
        var underlyingDelegate: NSWindowDelegate?

        init(shouldWarn: @escaping () -> Bool, onAttemptedClose: @escaping () -> Void) {
            self.shouldWarn = shouldWarn
            self.onAttemptedClose = onAttemptedClose
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if shouldWarn() {
                onAttemptedClose()
                return false
            }
            return underlyingDelegate?.windowShouldClose?(sender) ?? true
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(shouldWarn: shouldWarn, onAttemptedClose: onAttemptedClose)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.underlyingDelegate = window.delegate
            window.delegate = context.coordinator
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.shouldWarn = shouldWarn
        context.coordinator.onAttemptedClose = onAttemptedClose
    }
}

extension Notification.Name {
    /// Posted by `AppDelegate.applicationShouldTerminate` while an
    /// Apply is in flight — prompts the Brew Package Manager window
    /// to raise the quit warning dialog.
    static let steadingAppQuitDuringApply =
        Notification.Name("com.xalior.Steading.AppQuitDuringApply")
}

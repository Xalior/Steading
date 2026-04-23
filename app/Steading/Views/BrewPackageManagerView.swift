import SwiftUI
import AppKit

struct BrewPackageManagerView: View {
    @Environment(BrewUpdateManager.self) private var manager
    @Environment(AskpassService.self) private var askpass
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var marked: Set<String> = []
    @State private var detailsShown: Bool = false
    @State private var closeWarning: CloseReason?

    // Password modal is driven entirely by `askpass.pendingRequest` —
    // the modal appears only when the bundled `steading-askpass`
    // helper calls into the GUI over XPC, not when Apply is clicked.
    @State private var passwordInput = ""

    /// What triggered the close attempt — drives the Cancel-and-Close
    /// handler's follow-up action.
    enum CloseReason: Identifiable {
        case closeWindow
        case quitApp
        var id: Int { self == .closeWindow ? 0 : 1 }
    }

    private var buttons: BrewUpdateManager.Buttons {
        BrewUpdateManager.buttons(
            state: manager.state,
            markedCount: marked.intersection(Set(manager.outdated.map(\.name))).count,
            outdatedCount: manager.outdated.count
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            packageList
            Divider()
            controls
            if shouldShowProgressArea {
                Divider()
                progressArea
            }
        }
        .frame(minWidth: 620, idealWidth: 760, minHeight: 440, idealHeight: 560)
        .background(CloseInterceptor(shouldWarn: { manager.state == .applying },
                                     onAttemptedClose: { closeWarning = .closeWindow }))
        .confirmationDialog(
            "Cancel upgrade in progress?",
            isPresented: Binding(
                get: { closeWarning != nil },
                set: { if !$0 { closeWarning = nil } }
            ),
            titleVisibility: .visible,
            presenting: closeWarning
        ) { reason in
            Button("Keep Running", role: .cancel) { closeWarning = nil }
            Button("Cancel and Close Anyway", role: .destructive) {
                manager.cancelApply()
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
            Text("Stopping an upgrade midway is equivalent to pressing Ctrl-C during `brew upgrade`. Packages currently being installed may be left in a partial or broken state, and your Homebrew installation may need manual repair. This is strongly advised against.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .steadingAppQuitDuringApply)) { _ in
            closeWarning = .quitApp
        }
        .sheet(item: Binding(
            get: { askpass.pendingRequest },
            set: { new in
                // If the sheet is dismissed for any reason without the
                // user clicking Continue, treat it as cancel.
                if new == nil, askpass.pendingRequest != nil {
                    askpass.respondCancel()
                }
            }
        )) { _ in
            passwordModal
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            Text(headerText)
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var headerText: String {
        BrewUpdateManager.statusStripText(for: manager.state)
            ?? (manager.outdated.isEmpty ? "No updates pending" : "\(manager.outdated.count) pending updates")
    }

    @ViewBuilder
    private var packageList: some View {
        if case .failed(let message) = manager.state {
            VStack(spacing: 12) {
                Text("Last check failed: \(message)")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("Check Now") { manager.check() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if manager.outdated.isEmpty {
            VStack(spacing: 8) {
                if case .checking = manager.state {
                    ProgressView()
                    Text("Checking…").foregroundStyle(.secondary)
                } else {
                    Image(systemName: "checkmark.seal")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No updates pending").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            List {
                ForEach(manager.outdated, id: \.name) { pkg in
                    packageRow(pkg)
                }
            }
            .listStyle(.plain)
        }
    }

    private func packageRow(_ pkg: OutdatedPackage) -> some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(
                get: { marked.contains(pkg.name) },
                set: { isOn in
                    if isOn { marked.insert(pkg.name) } else { marked.remove(pkg.name) }
                }
            )) { EmptyView() }
                .toggleStyle(.checkbox)
                .disabled(!buttons.perRowEnabled)

            VStack(alignment: .leading, spacing: 2) {
                Text(pkg.name).font(.body.weight(.semibold))
                Text("\(pkg.installedVersion) → \(pkg.availableVersion)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            Text(pkg.kind == .formula ? "Formula" : "Cask")
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(pkg.kind == .formula
                                   ? Color.blue.opacity(0.15)
                                   : Color.purple.opacity(0.15))
                )
                .foregroundStyle(pkg.kind == .formula ? .blue : .purple)
        }
        .padding(.vertical, 2)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button("Mark All Upgrades") {
                marked = Set(manager.outdated.map(\.name))
            }
            .disabled(!buttons.markAllEnabled)

            Button("Check Now") { manager.check() }
                .disabled(!buttons.checkNowEnabled)

            Spacer()

            if buttons.cancelEnabled {
                Button("Cancel", role: .destructive) {
                    manager.cancelApply()
                    askpass.respondCancel()
                }
            }

            Button("Apply") {
                let toApply = manager.outdated.filter { marked.contains($0.name) }
                manager.apply(toApply)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!buttons.applyEnabled)
        }
        .padding(12)
    }

    private var shouldShowProgressArea: Bool {
        if case .applying = manager.state { return true }
        return manager.recentApplyOutcome != nil
    }

    @ViewBuilder
    private var progressArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if case .applying = manager.state {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                } else if let outcome = manager.recentApplyOutcome {
                    outcomeIndicator(for: outcome)
                }
            }

            DisclosureGroup(isExpanded: $detailsShown) {
                ScrollView {
                    Text(manager.applyLog.isEmpty ? "(no output yet)" : manager.applyLog)
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
    private func outcomeIndicator(for outcome: BrewUpdateManager.ApplyOutcome) -> some View {
        switch outcome {
        case .success:
            Label("Upgrade complete.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let code):
            Label("brew upgrade exited \(code).", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .cancelled:
            Label("Last upgrade canceled.", systemImage: "stop.circle.fill")
                .foregroundStyle(.orange)
        case .spawnFailed(let reason):
            Label("Could not start brew: \(reason)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
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
            Text("brew is asking for an administrator password to finish the current upgrade. Your password is used once and not stored.")
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

// MARK: - Close interception

/// NSWindowDelegate bridge that routes the window's close gestures
/// (red button, Cmd+W) through a warning when a gate predicate is
/// true. The predicate runs at close time, so it's re-evaluated on
/// every attempt.
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

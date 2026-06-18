import SwiftUI
import AppKit

/// The single "Applying…" surface every user-triggered brew mutation
/// presents — the package manager's Apply, the Tailscale install,
/// future per-service installs. Bound to the shared `BrewPackageManager`
/// engine and `AskpassService`; owns the streaming-output view, the
/// outcome indicator, Cancel/Done, and the password + autoremove
/// prompts brew can raise mid-run.
///
/// Presented as a window-modal sheet by whichever window owns the job
/// (see `BrewPackageManager.ownerWindowID`). While applying, the sheet
/// is non-dismissible — the only way out is Cancel — so a job can't be
/// orphaned by an accidental dismiss.
struct BrewApplyView: View {
    @Environment(BrewPackageManager.self) private var packages
    @Environment(AskpassService.self) private var askpass

    @State private var passwordInput = ""
    @State private var rememberPassword = false
    @State private var cacheDuration: AskpassService.CacheDuration = .fiveMinutes
    @State private var quitWarning = false
    @State private var confirmCancel = false

    /// Stable identity for the invisible element at the end of the log
    /// scroll view; scrolling to it follows the streaming tail.
    private let logTailAnchor = "apply-log-tail"

    private var isApplying: Bool { packages.state == .applying }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            statusRow
            logArea
            Divider()
            buttonRow
        }
        .padding(20)
        .frame(width: 580, height: 480)
        .interactiveDismissDisabled(isApplying)
        // Password prompt brew can raise when a sub-call needs sudo.
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
        // Post-uninstall autoremove confirmation.
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
        // Security anomaly from the askpass listener.
        .alert("Security warning", isPresented: Binding(
            get: { askpass.securityWarning != nil },
            set: { if !$0 { askpass.securityWarning = nil } }
        )) {
            Button("OK", role: .cancel) { askpass.securityWarning = nil }
        } message: {
            Text(askpass.securityWarning ?? "")
        }
        // Quit attempted mid-apply: AppDelegate deferred termination and
        // posted this so the user can confirm. Only fires while the
        // modal is up (i.e. while applying), so it lives here.
        .onReceive(NotificationCenter.default.publisher(for: .steadingAppQuitDuringApply)) { _ in
            quitWarning = true
        }
        .confirmationDialog(
            "Quit while changes are being applied?",
            isPresented: $quitWarning,
            titleVisibility: .visible
        ) {
            Button("Cancel Apply and Quit", role: .destructive) {
                packages.cancelApply()
                askpass.respondCancel()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            Button("Keep Running", role: .cancel) {
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        } message: {
            Text("Stopping mid-pipeline is like pressing Ctrl-C during a brew sub-call. Packages being installed or removed may be left in a partial or broken state, and your Homebrew installation may need manual repair.")
        }
    }

    // MARK: - Header / status

    private var header: some View {
        Text(isApplying ? "Applying changes…" : "Apply complete")
            .font(.title2.weight(.semibold))
    }

    @ViewBuilder
    private var statusRow: some View {
        if isApplying {
            ProgressView()
                .progressViewStyle(.linear)
                .frame(maxWidth: .infinity)
        } else if let outcome = packages.recentApplyOutcome {
            outcomeIndicator(for: outcome)
        }
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

    // MARK: - Streaming log

    private var logArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(packages.applyLog.isEmpty ? "(no output yet)" : packages.applyLog)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    Color.clear
                        .frame(height: 1)
                        .id(logTailAnchor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.secondary.opacity(0.3))
            )
            .onChange(of: packages.applyLog) { _, _ in
                proxy.scrollTo(logTailAnchor, anchor: .bottom)
            }
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private var buttonRow: some View {
        HStack {
            Spacer()
            if isApplying {
                Button("Cancel", role: .destructive) { confirmCancel = true }
            } else {
                Button("Done") { packages.dismissResult() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .confirmationDialog(
            "Stop while changes are being applied?",
            isPresented: $confirmCancel,
            titleVisibility: .visible
        ) {
            Button("Stop and risk a broken state", role: .destructive) {
                packages.cancelApply()
                askpass.respondCancel()
            }
            Button("Keep Running", role: .cancel) {}
        } message: {
            Text("Stopping mid-pipeline is like pressing Ctrl-C during a brew sub-call. Packages currently being installed or removed may be left in a partial or broken state, and your Homebrew installation may need manual repair.")
        }
    }

    // MARK: - Password modal

    private func submitPassword() {
        let value = passwordInput
        passwordInput = ""
        askpass.respond(password: value,
                        cache: rememberPassword ? cacheDuration : nil)
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
            Text("brew is asking for an administrator password to finish the current sub-call. By default your password isn't stored — enable Remember to keep it in memory for the chosen duration.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if askpass.lastValidationFailed {
                Text("That password was incorrect. Try again.")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            SecureField("Password", text: $passwordInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submitPassword() }
                .disabled(askpass.isValidating)

            Toggle("Remember password", isOn: $rememberPassword)
                .disabled(askpass.isValidating)
            if rememberPassword {
                Picker("For", selection: $cacheDuration) {
                    ForEach(AskpassService.CacheDuration.allCases) { duration in
                        Text(duration.label).tag(duration)
                    }
                }
                .pickerStyle(.menu)
                .disabled(askpass.isValidating)
            }

            HStack {
                if askpass.isValidating {
                    ProgressView().controlSize(.small)
                    Text("Validating…").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { cancelPassword() }
                    .disabled(askpass.isValidating)
                Button("Continue") { submitPassword() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(passwordInput.isEmpty || askpass.isValidating)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// Presents the shared `BrewApplyView` as a window-modal sheet whenever
/// the engine's `ownerWindowID` matches this window. Each window that
/// can launch a brew job attaches this with its own scene id, so the
/// modal appears over exactly the window that started the job and never
/// two at once.
struct BrewApplyPresenter: ViewModifier {
    @Environment(BrewPackageManager.self) private var packages
    @Environment(AskpassService.self) private var askpass
    let windowID: String

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { packages.ownerWindowID == windowID },
            set: { presented in
                // Dismiss only routes through the engine; the sheet
                // can't be dismissed while applying (interactiveDismiss
                // is disabled), so this fires on Done.
                if !presented { packages.dismissResult() }
            }
        )) {
            // Re-inject: sheet content doesn't reliably inherit
            // `.environment` Observables from the presenter.
            BrewApplyView()
                .environment(packages)
                .environment(askpass)
        }
    }
}

extension View {
    /// Attach the shared brew "Applying…" modal for `windowID`.
    func brewApplyModal(for windowID: String) -> some View {
        modifier(BrewApplyPresenter(windowID: windowID))
    }
}

extension Notification.Name {
    /// Posted by `AppDelegate.applicationShouldTerminate` while an
    /// Apply is in flight — prompts the shared apply modal to raise the
    /// quit confirmation.
    static let steadingAppQuitDuringApply =
        Notification.Name("com.xalior.Steading.AppQuitDuringApply")
}

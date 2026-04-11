import SwiftUI
import AppKit

/// First-run onboarding screen. Shown when any prerequisite is
/// missing — Homebrew isn't installed, the privileged helper isn't
/// registered, or it's still awaiting the user's approval in
/// System Settings. Auto-transitions to the main UI the moment
/// `AppState.isReady` flips true.
struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @State private var isRegistering = false

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                header

                VStack(spacing: 16) {
                    BrewPrerequisiteCard(state: appState.brewCheck)
                    HelperPrerequisiteCard(
                        state: appState.helperCheck,
                        isRegistering: isRegistering,
                        onRegister: register,
                        onOpenSettings: { PrivHelperClient.shared.openLoginItemsSettings() },
                        onRefresh: { appState.refreshHelperStatus() }
                    )
                    if let error = appState.registrationError {
                        errorBanner(error)
                    }
                }
                .frame(maxWidth: 520)

                footerNote
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            // Re-check helper state when the user comes back from
            // System Settings; if they approved us, isReady flips
            // true and SwiftUI swaps this view out automatically.
            appState.refreshHelperStatus()
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "house.fill")
                .font(.system(size: 64, weight: .regular))
                .foregroundStyle(.tint)
            Text("Welcome to Steading")
                .font(.system(size: 34, weight: .semibold))
            Text("Before we start, Steading needs a couple of things in place.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 20)
    }

    private var footerNote: some View {
        Text("Steading's main app stays unprivileged. Root operations go through a small helper tool managed by launchd — you'll approve it once in System Settings, then never again.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 520)
    }

    // MARK: - Actions

    private func register() {
        isRegistering = true
        defer { isRegistering = false }
        appState.registerHelper()
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 0.5)
        )
    }
}

// MARK: - Brew prerequisite card

private struct BrewPrerequisiteCard: View {
    let state: AppState.BrewCheckState

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            icon
                .font(.system(size: 28))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(tint.opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 3) {
                Text("Homebrew")
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospaced()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.background.secondary)
        )
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .idle, .checking:
            ProgressView().controlSize(.small)
        case .ready(.installed):
            Image(systemName: "checkmark.circle.fill")
        case .ready(.foundButUnresponsive):
            Image(systemName: "exclamationmark.triangle.fill")
        case .ready(.notFound):
            Image(systemName: "xmark.circle.fill")
        }
    }

    private var tint: Color {
        switch state {
        case .idle, .checking:              return .secondary
        case .ready(.installed):            return .green
        case .ready(.foundButUnresponsive): return .orange
        case .ready(.notFound):             return .red
        }
    }

    private var subtitle: String {
        switch state {
        case .idle, .checking:
            return "Checking…"
        case .ready(.installed(let path, let version)):
            return "\(version) · \(path)"
        case .ready(.foundButUnresponsive(let path)):
            return "Found at \(path) but did not respond"
        case .ready(.notFound):
            return "Not installed — Steading needs Homebrew"
        }
    }
}

// MARK: - Helper prerequisite card

private struct HelperPrerequisiteCard: View {
    let state: AppState.HelperCheckState
    let isRegistering: Bool
    let onRegister: () -> Void
    let onOpenSettings: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                icon
                    .font(.system(size: 28))
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(tint.opacity(0.12))
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text("Privileged Helper")
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            actions
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.background.secondary)
        )
    }

    @ViewBuilder
    private var actions: some View {
        switch state {
        case .idle, .checking, .ready(.enabled):
            EmptyView()
        case .ready(.notRegistered), .ready(.notFound), .ready(.unknown):
            Button(action: onRegister) {
                Label("Register Privileged Helper", systemImage: "key.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isRegistering)
        case .ready(.requiresApproval):
            HStack(spacing: 10) {
                Button(action: onOpenSettings) {
                    Label("Open Login Items…", systemImage: "gear")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: onRefresh) {
                    Label("Re-check", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .idle, .checking:
            ProgressView().controlSize(.small)
        case .ready(.enabled):
            Image(systemName: "checkmark.circle.fill")
        case .ready(.requiresApproval):
            Image(systemName: "clock.badge.exclamationmark")
        case .ready(.notRegistered), .ready(.notFound):
            Image(systemName: "xmark.circle.fill")
        case .ready(.unknown):
            Image(systemName: "questionmark.circle.fill")
        }
    }

    private var tint: Color {
        switch state {
        case .idle, .checking:              return .secondary
        case .ready(.enabled):              return .green
        case .ready(.requiresApproval):     return .orange
        case .ready(.notRegistered):        return .red
        case .ready(.notFound):             return .red
        case .ready(.unknown):              return .secondary
        }
    }

    private var subtitle: String {
        switch state {
        case .idle, .checking:
            return "Checking helper status…"
        case .ready(.enabled):
            return "Registered with launchd. Ready to run root operations for built-in services."
        case .ready(.requiresApproval):
            return "Waiting for you to enable Steading under System Settings → General → Login Items & Extensions."
        case .ready(.notRegistered):
            return "Steading will register a privileged helper with macOS. You'll be asked to approve it once in System Settings — never again after that."
        case .ready(.notFound):
            return "Helper binary is missing from the app bundle. Rebuild the app."
        case .ready(.unknown):
            return "Could not determine helper status."
        }
    }
}

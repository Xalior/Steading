import SwiftUI

/// Detail pane for the Tailscale service. Renders one of three states
/// off the launch-time detection snapshot in `AppState.tailscaleCheck`:
///
/// - a **GUI variant** (MAS or standalone `Tailscale.app`) is present →
///   a gate explaining why it must be removed, with uninstall steps;
/// - **nothing** is installed → onboarding copy plus an *Install
///   Tailscale (via Homebrew)* button;
/// - the **open-source** CLI/daemon is installed → a confirmation.
struct TailscaleDetailView: View {
    let item: CatalogItem

    @Environment(AppState.self) private var appState
    @State private var installer = TailscaleInstaller()
    @State private var logShown = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                content
                Spacer(minLength: 0)
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: installer.state) { _, newState in
            // Our own install is the one in-session change that makes
            // Tailscale appear, so re-detect to flip the pane to the
            // installed state.
            if case .finished(success: true) = newState {
                Task { await appState.refreshTailscaleStatus() }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: item.symbol)
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 56, height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.tint.opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.largeTitle.weight(.semibold))
                Text("\(item.kind.label) · \(item.subtitle)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - State dispatch

    @ViewBuilder
    private var content: some View {
        switch appState.tailscaleCheck {
        case .idle, .checking:
            detectingCard
        case .ready(let status):
            switch status {
            case .guiVariantPresent(let variant, _):
                gateCard(variant: variant)
            case .openSourceInstalled(let path):
                installedCard(path: path)
            case .notInstalled:
                onboardingCard
            }
        }
    }

    private var detectingCard: some View {
        card {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking for an existing Tailscale install…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Gate (a GUI variant is installed)

    private func gateCard(variant: TailscaleDetector.Variant) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Remove the \(variant.displayName) first", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text("""
                        Steading brings Tailscale up at boot, before anyone logs in. \
                        The \(variant.displayName) of Tailscale connects only after you log \
                        in, so it can't do that — and it can't run alongside the open-source \
                        version Steading manages. Remove it, then Steading can install and \
                        manage the open-source build. To learn more see the [Tailscale documentation](https://tailscale.com/docs/concepts/macos-variants).
                        """)
                        .font(.body)
                        .foregroundStyle(.primary.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("To remove it")
                        .font(.headline)
                    step(1, "Quit Tailscale from its menu bar icon.")
                    step(2, "Drag Tailscale from Applications to the Trash.")
                    step(3, "Empty the Trash.")
                    step(4, "Restart your Mac.")
                    Text("Steading re-checks at the next launch — after the reboot it will offer to install the open-source version.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n).")
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Onboarding (nothing installed)

    private var onboardingCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("About")
                        .font(.headline)
                    Text(item.summary)
                        .font(.body)
                        .foregroundStyle(.primary.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            exitNodeNote

            installCard
        }
    }

    /// The current exit-node limitation of the open-source macOS build.
    private var exitNodeNote: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Exit nodes", systemImage: "arrow.triangle.branch")
                    .font(.headline)
                Text("""
                    Steading can advertise this Mac as an exit node for your tailnet, so other \
                    devices can route their traffic out through it. The open-source macOS build \
                    cannot currently use another node as its own exit node — this Mac can be an \
                    exit node, but it can't route through one.
                    """)
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var installCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    installer.install()
                } label: {
                    Label("Install Tailscale (via Homebrew)", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(installer.state == .installing)

                installProgress
            }
        }
    }

    @ViewBuilder
    private var installProgress: some View {
        switch installer.state {
        case .idle:
            EmptyView()
        case .installing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Installing the tailscale formula…")
                    .foregroundStyle(.secondary)
            }
            outputDisclosure
        case .finished(let success):
            if success {
                Label("Installed.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Install failed.", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Button("Try Again") { installer.install() }
                }
                outputDisclosure
            }
        }
    }

    @ViewBuilder
    private var outputDisclosure: some View {
        if !installer.logTail.isEmpty {
            DisclosureGroup(isExpanded: $logShown) {
                ScrollView {
                    Text(installer.logTail)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(height: 160)
                .background(Color(NSColor.textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3))
                )
            } label: {
                Text(logShown ? "Hide output" : "Show output")
                    .font(.caption)
            }
        }
    }

    // MARK: - Installed

    private func installedCard(path: String) -> some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Open-source Tailscale installed", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Text("Steading detected the open-source Tailscale build — the variant it can run as a boot-time daemon.")
                    .font(.body)
                    .foregroundStyle(.primary.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                Text(path)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Card chrome

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.background.secondary)
            )
    }
}

private extension TailscaleDetector.Variant {
    /// Human-facing name for the variant, used in the gate copy.
    var displayName: String {
        switch self {
        case .appStore:   return "Mac App Store version"
        case .standalone: return "standalone (direct-download) version"
        }
    }
}

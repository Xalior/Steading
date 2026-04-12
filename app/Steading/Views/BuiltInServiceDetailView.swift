import SwiftUI

/// Detail view for macOS built-in services. Replaces the generic
/// `CatalogDetailView` when the selected catalog item has
/// `.kind == .builtIn`. Shows live state from the matching
/// `BuiltInServiceRunner` and — when an enable/disable command
/// exists — offers Enable / Disable buttons that route through
/// `PrivilegedShell`.
struct BuiltInServiceDetailView: View {
    let item: CatalogItem
    let runner: BuiltInServiceRunner

    @State private var state: BuiltInServiceState = .unknown(reason: "")
    @State private var isRefreshing = false
    @State private var isApplying = false
    @State private var errorMessage: String?
    @State private var needsApproval = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                summaryCard
                stateCard
                actionsCard
                detectionFooter
                if let errorMessage {
                    errorBanner(errorMessage, showOpenSettings: needsApproval)
                }
                Spacer(minLength: 0)
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: item.id) { await refresh() }
    }

    // MARK: - Sections

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
                Text(runner.displayName)
                    .font(.largeTitle.weight(.semibold))
                Text("macOS Built-in · \(item.subtitle)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await refresh() }
            } label: {
                if isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isRefreshing)
            .help("Re-read current state")
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Summary")
                .font(.headline)
            Text(item.summary)
                .font(.body)
                .foregroundStyle(.primary.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.background.secondary)
        )
    }

    private var stateCard: some View {
        HStack(alignment: .top, spacing: 16) {
            stateIcon
                .font(.system(size: 28))
                .frame(width: 44, height: 44)
                .foregroundStyle(stateTint)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(stateTint.opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(stateTitle)
                    .font(.title3.weight(.semibold))
                if let subtitle = stateSubtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.background.secondary)
        )
    }

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if runner.enableCommand != nil {
                    Button {
                        Task { await enable() }
                    } label: {
                        Label("Enable \(runner.displayName)", systemImage: "power")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isApplying || isRefreshing || currentlyOn == true)
                }
                if runner.disableCommand != nil {
                    Button {
                        Task { await disable() }
                    } label: {
                        Label("Disable \(runner.displayName)", systemImage: "power.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(isApplying || isRefreshing || currentlyOn == false)
                }
                if runner.enableCommand == nil && runner.disableCommand == nil {
                    Text("Interactive configuration is not yet wired up for this service.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if isApplying {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var detectionFooter: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(runner.detectionNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func errorBanner(_ message: String, showOpenSettings: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            if showOpenSettings {
                Button("Open Login Items Settings") {
                    PrivHelperClient.shared.openLoginItemsSettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 0.5)
        )
    }

    // MARK: - State mapping

    private var stateIcon: Image {
        switch state {
        case .enabled:                    return Image(systemName: "checkmark.circle.fill")
        case .disabled:                   return Image(systemName: "pause.circle.fill")
        case .custom(_, .some(true)):     return Image(systemName: "checkmark.circle.fill")
        case .custom(_, .some(false)):    return Image(systemName: "pause.circle.fill")
        case .custom(_, .none):           return Image(systemName: "gearshape.fill")
        case .unknown:                    return Image(systemName: "questionmark.circle.fill")
        case .error:                      return Image(systemName: "exclamationmark.circle.fill")
        }
    }

    private var stateTint: Color {
        switch state {
        case .enabled:                    return .green
        case .disabled:                   return .secondary
        case .custom(_, .some(true)):     return .green
        case .custom(_, .some(false)):    return .secondary
        case .custom(_, .none):           return .accentColor
        case .unknown:                    return .secondary
        case .error:                      return .orange
        }
    }

    private var stateTitle: String {
        switch state {
        case .enabled:                    return "Enabled"
        case .disabled:                   return "Disabled"
        case .custom(let summary, _):     return summary
        case .unknown:                    return "Unknown"
        case .error:                      return "Error"
        }
    }

    private var stateSubtitle: String? {
        switch state {
        case .enabled:                    return "Service is currently turned on."
        case .disabled:                   return "Service is currently turned off."
        case .custom:                     return "Current values from pmset."
        case .unknown(let reason):        return reason.isEmpty ? nil : reason
        case .error(let message):         return message
        }
    }

    private var currentlyOn: Bool? {
        switch state {
        case .enabled:                    return true
        case .disabled:                   return false
        case .custom(_, let isOn):        return isOn
        case .unknown, .error:            return nil
        }
    }

    // MARK: - Actions

    private func refresh() async {
        isRefreshing = true
        errorMessage = nil
        state = await runner.readState()
        isRefreshing = false
    }

    private func enable() async {
        guard let cmd = runner.enableCommand else { return }
        await apply(cmd, label: "enable")
    }

    private func disable() async {
        guard let cmd = runner.disableCommand else { return }
        await apply(cmd, label: "disable")
    }

    private func apply(_ command: [String], label: String) async {
        isApplying = true
        errorMessage = nil
        needsApproval = false
        defer { isApplying = false }
        do {
            try PrivHelperClient.shared.registerIfNeeded()
            let result = try await PrivHelperClient.shared.runCommand(command)
            if !result.ok {
                let raw = result.stderr.isEmpty ? result.stdout : result.stderr
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                errorMessage = "Failed to \(label) (exit \(result.exitCode))"
                    + (trimmed.isEmpty ? "" : ": \(trimmed)")
                return
            }
            state = await runner.readState()
        } catch let error as PrivHelperClient.Error {
            errorMessage = error.localizedDescription
            if case .requiresApproval = error { needsApproval = true }
        } catch {
            errorMessage = "Failed to \(label): \(error.localizedDescription)"
        }
    }
}

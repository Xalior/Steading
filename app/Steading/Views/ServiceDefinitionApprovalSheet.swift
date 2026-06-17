import SwiftUI

/// Modal blocking sheet shown at app launch when the registry
/// contains any service-definition YAMLs whose hash isn't already
/// on the helper's approvals list — modified bundle YAMLs, brand-
/// new external YAMLs, or approved-but-since-changed entries that
/// need re-approval.
///
/// The sheet walks pending records one at a time. For each, the
/// user sees the YAML's path, origin label, and the explicit list
/// of files/directories the YAML declares writes to. Approving
/// triggers an admin-password / Touch ID challenge via
/// `AdminAuthorization`; on success the helper records the
/// approval. Denying drops the entry without prompting.
///
/// The sheet stays modal until every pending record is resolved;
/// `ContentView` only renders once `pendingApprovals.isEmpty`.
struct ServiceDefinitionApprovalSheet: View {
    @Environment(AppState.self) private var appState
    @State private var error: String?
    @State private var inFlight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let record = appState.definitionRegistry.pendingApprovals.first {
                header(record: record)
                Divider()
                writeTargets(record: record)
                if let error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Spacer()
                actions(record: record)
            } else {
                Text("All service definitions approved.").font(.headline)
            }
        }
        .padding(24)
        .frame(minWidth: 540, minHeight: 420)
    }

    @ViewBuilder
    private func header(record: DefinitionRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Approve service definition")
                .font(.title2)
                .bold()
            Text("Steading found a service-definition YAML that hasn't been approved yet. Review the writes it declares before approving.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Label(originLabel(record.origin), systemImage: originIcon(record.origin))
                    .font(.callout)
                Spacer()
            }
            Text(record.yamlPath)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func writeTargets(record: DefinitionRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Service: \(record.definition.displayName) (\(record.definition.serviceID))")
                .font(.headline)
            if record.definition.writeTargets.isEmpty {
                Text("This YAML declares no privileged writes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Approving permits the helper to perform these writes:")
                    .font(.callout)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(record.definition.writeTargets.enumerated()), id: \.offset) { _, t in
                            HStack(alignment: .firstTextBaseline) {
                                Text(kindBadge(t.kind))
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 80, alignment: .leading)
                                Text(t.path)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                Spacer()
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
    }

    @ViewBuilder
    private func actions(record: DefinitionRecord) -> some View {
        HStack {
            Button("Deny") {
                appState.deny(record: record)
            }
            .keyboardShortcut(.cancelAction)
            .disabled(inFlight)
            Spacer()
            Button {
                inFlight = true
                error = nil
                Task {
                    do {
                        try await appState.approve(record: record)
                    } catch {
                        self.error = String(describing: error)
                    }
                    inFlight = false
                }
            } label: {
                if inFlight {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Approve…")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(inFlight)
        }
    }

    private func originLabel(_ origin: DefinitionOrigin) -> String {
        switch origin {
        case .bundleTrusted:  return "Bundled (trusted)"
        case .bundleModified: return "Bundled (modified)"
        case .external:       return "External"
        }
    }

    private func originIcon(_ origin: DefinitionOrigin) -> String {
        switch origin {
        case .bundleTrusted:  return "shield"
        case .bundleModified: return "exclamationmark.shield"
        case .external:       return "externaldrive"
        }
    }

    private func kindBadge(_ kind: WriteTarget.Kind) -> String {
        switch kind {
        case .literal:   return "FILE"
        case .template:  return "TEMPLATE"
        case .directory: return "DIR"
        }
    }
}

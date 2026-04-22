import SwiftUI

/// Raw text editor for `/etc/hosts`, reached via the **Tools → Edit
/// /etc/hosts…** command.
///
/// Scope:
/// - Reads `/etc/hosts` verbatim (no parsing, no mutation — comments
///   and commented-out entries pass through untouched).
/// - Writes the user's edited buffer back through the privileged
///   helper's `writeHostsFile` XPC method, which pins the path and
///   writes atomically as `root:wheel 0644`.
/// - "Preserve existing content" is the user's responsibility: this
///   is a text editor, not a structured editor. That's an explicit
///   scoping decision — a structured editor that round-trips comments
///   is deferred.
struct HostsEditorView: View {

    @State private var loadedContent: String = ""
    @State private var buffer: String = ""
    @State private var status: Status = .loading
    @State private var errorMessage: String?
    @State private var isSaving = false

    @Environment(\.dismissWindow) private var dismissWindow

    private let hostsPath = "/etc/hosts"

    enum Status {
        case loading
        case loaded
        case failedToLoad
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            editor
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 480)
        .task { await load() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "doc.text")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Edit /etc/hosts")
                    .font(.title3.weight(.semibold))
                Text("Saved atomically as root:wheel 0644 via the privileged helper.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isDirty {
                Text("Unsaved changes")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var editor: some View {
        Group {
            switch status {
            case .loading:
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failedToLoad:
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.red)
                    Text(errorMessage ?? "Could not read /etc/hosts")
                        .foregroundStyle(.secondary)
                    Button("Retry") { Task { await load() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                TextEditor(text: $buffer)
                    .font(.system(.body, design: .monospaced))
                    .disableAutocorrection(true)
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let errorMessage, status == .loaded {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            Button("Reload") {
                Task { await load() }
            }
            .disabled(isSaving)

            Button("Cancel") {
                dismissWindow(id: "hosts-editor")
            }
            .keyboardShortcut(.cancelAction)

            Button {
                Task { await save() }
            } label: {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Save")
                }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(isSaving || status != .loaded || !isDirty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Behaviour

    private var isDirty: Bool { buffer != loadedContent }

    private func load() async {
        status = .loading
        errorMessage = nil
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: hostsPath))
            guard let text = String(data: data, encoding: .utf8) else {
                status = .failedToLoad
                errorMessage = "/etc/hosts is not valid UTF-8"
                return
            }
            loadedContent = text
            buffer = text
            status = .loaded
        } catch {
            status = .failedToLoad
            errorMessage = "Could not read \(hostsPath): \(error.localizedDescription)"
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await PrivHelperClient.shared.writeHostsFile(buffer)
            loadedContent = buffer
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

import SwiftUI

/// Narrow post-onboarding status strip. Binds to `BrewUpdateManager`
/// and renders one of the three context-aware messages — or nothing,
/// when there's nothing pending to report.
struct BottomStatusStrip: View {
    @Environment(BrewUpdateManager.self) private var manager

    var body: some View {
        if let text = BrewUpdateManager.statusStripText(for: manager.state) {
            HStack(spacing: 8) {
                if case .checking = manager.state {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .top) {
                Divider()
            }
        }
    }
}

extension BrewUpdateManager {
    /// Render the state as the strip's one-line message. Returns `nil`
    /// when the strip should be hidden — the `.idle(count: 0)` case.
    /// Pure; exposed for tests and window reuse in later phases.
    nonisolated static func statusStripText(for state: State) -> String? {
        switch state {
        case .idle(let count) where count <= 0:
            return nil
        case .idle(let count):
            return count == 1 ? "1 pending update" : "\(count) pending updates"
        case .checking:
            return "Checking…"
        case .failed(let message):
            return "Last check failed: \(message)"
        case .applying:
            return "Upgrading…"
        }
    }
}

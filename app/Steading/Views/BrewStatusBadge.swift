import SwiftUI

/// Compact brew status pill for the window toolbar.
struct BrewStatusBadge: View {
    let state: AppState.BrewCheckState

    var body: some View {
        HStack(spacing: 6) {
            icon
            Text(label)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(tint.opacity(0.12))
        )
        .overlay(
            Capsule().stroke(tint.opacity(0.35), lineWidth: 0.5)
        )
        .help(helpText)
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .idle, .checking:
            ProgressView().controlSize(.mini)
        case .ready(.installed):
            Image(systemName: "checkmark.circle.fill")
        case .ready(.foundButUnresponsive):
            Image(systemName: "exclamationmark.triangle.fill")
        case .ready(.notFound):
            Image(systemName: "xmark.circle.fill")
        }
    }

    private var label: String {
        switch state {
        case .idle, .checking:           return "Homebrew: checking…"
        case .ready(.installed(_, let v)): return "Homebrew \(v)"
        case .ready(.foundButUnresponsive): return "Homebrew: not responding"
        case .ready(.notFound):          return "Homebrew: not found"
        }
    }

    private var tint: Color {
        switch state {
        case .idle, .checking:           return .secondary
        case .ready(.installed):         return .green
        case .ready(.foundButUnresponsive): return .orange
        case .ready(.notFound):          return .red
        }
    }

    private var helpText: String {
        switch state {
        case .ready(.installed(let path, let version)):
            return "Homebrew \(version) at \(path)"
        case .ready(.foundButUnresponsive(let path)):
            return "Homebrew binary at \(path) did not return a version"
        case .ready(.notFound):
            return "No Homebrew found in standard locations"
        default:
            return "Checking for Homebrew…"
        }
    }
}

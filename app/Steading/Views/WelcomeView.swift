import SwiftUI

struct WelcomeView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "house.fill")
                .font(.system(size: 72, weight: .regular))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("Steading")
                    .font(.system(size: 40, weight: .semibold))
                Text("Small Business Server for macOS")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            BrewStatusCard(state: appState.brewCheck)
                .frame(maxWidth: 460)

            Text("Choose a catalog entry on the left to see what it would install.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct BrewStatusCard: View {
    let state: AppState.BrewCheckState

    var body: some View {
        HStack(spacing: 14) {
            icon
                .font(.system(size: 24))
                .foregroundStyle(tint)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospaced()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.background.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(tint.opacity(0.25), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .idle:
            Image(systemName: "questionmark.circle")
        case .checking:
            ProgressView().controlSize(.small)
        case .ready(.installed):
            Image(systemName: "checkmark.seal.fill")
        case .ready(.foundButUnresponsive):
            Image(systemName: "exclamationmark.triangle.fill")
        case .ready(.notFound):
            Image(systemName: "xmark.octagon.fill")
        }
    }

    private var tint: Color {
        switch state {
        case .idle:                      return .secondary
        case .checking:                  return .accentColor
        case .ready(.installed):         return .green
        case .ready(.foundButUnresponsive): return .orange
        case .ready(.notFound):          return .red
        }
    }

    private var title: String {
        switch state {
        case .idle:                      return "Checking for Homebrew…"
        case .checking:                  return "Checking for Homebrew…"
        case .ready(.installed):         return "Homebrew is installed."
        case .ready(.foundButUnresponsive): return "Homebrew binary found, but not responding."
        case .ready(.notFound):          return "Homebrew is not installed."
        }
    }

    private var detail: String? {
        switch state {
        case .ready(.installed(let path, let version)):
            return "\(path)  ·  \(version)"
        case .ready(.foundButUnresponsive(let path)):
            return path
        case .ready(.notFound):
            return "Steading needs Homebrew to manage services."
        default:
            return nil
        }
    }
}

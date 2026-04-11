import SwiftUI

struct CatalogDetailView: View {
    let item: CatalogItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                summaryCard

                if !item.dependencies.isEmpty {
                    dependenciesCard
                }

                actionsCard

                Spacer(minLength: 0)
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

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

    private var dependenciesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pulls in")
                .font(.headline)
            HStack(spacing: 8) {
                ForEach(item.dependencies, id: \.self) { dep in
                    Text(dep)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(Color.accentColor.opacity(0.15))
                        )
                        .overlay(
                            Capsule().stroke(Color.accentColor.opacity(0.35), lineWidth: 0.5)
                        )
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.background.secondary)
        )
    }

    private var actionsCard: some View {
        HStack(spacing: 12) {
            Button {
                // PoC: no-op. Real install flow will live here.
            } label: {
                Label("Install", systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(true)

            Button {
                // PoC: no-op.
            } label: {
                Label("Open Definition", systemImage: "doc.text.magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .disabled(true)
        }
        .overlay(alignment: .bottomLeading) {
            Text("PoC — actions disabled")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 48)
        }
    }
}

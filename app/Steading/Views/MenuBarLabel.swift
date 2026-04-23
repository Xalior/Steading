import SwiftUI

/// Custom label for the `MenuBarExtra`. Always shows the house icon;
/// appends the pending-update count when `notifyMenuBarLabel` is on
/// and the manager has reported a non-zero settled count.
struct MenuBarLabel: View {
    @Environment(BrewUpdateManager.self) private var manager
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "house.fill")
            if BrewUpdateManager.menuBarShowsCount(
                count: manager.lastSettledCount,
                enabled: preferences.notifyMenuBarLabel
            ) {
                Text("\(manager.lastSettledCount)")
                    .font(.body.monospacedDigit())
            }
        }
    }
}

/// Invisible controller that binds the manager's settled count to
/// `NSApplication.shared.dockTile.badgeLabel` and to the
/// banner-on-pref-change logic.
struct NotificationSurfaceController: View {
    @Environment(BrewUpdateManager.self) private var manager
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { updateDock() }
            .onChange(of: manager.lastSettledCount) { _, _ in updateDock() }
            .onChange(of: preferences.notifyDockBadge) { _, _ in updateDock() }
            .onChange(of: preferences.notifySystemBanner) { _, _ in
                manager.preferencesChanged()
            }
    }

    private func updateDock() {
        NSApplication.shared.dockTile.badgeLabel = BrewUpdateManager.dockBadgeLabel(
            count: manager.lastSettledCount,
            enabled: preferences.notifyDockBadge
        )
    }
}

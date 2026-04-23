import SwiftUI

struct PreferencesView: View {
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        @Bindable var prefs = preferences

        Form {
            Section("Update checks") {
                Stepper(
                    value: $prefs.checkIntervalHours,
                    in: PreferencesStore.minCheckIntervalHours
                       ... PreferencesStore.maxCheckIntervalHours,
                    step: 1
                ) {
                    HStack {
                        Text("Check interval")
                        Spacer()
                        Text("\(prefs.checkIntervalHours) h")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Check on launch", isOn: $prefs.checkOnLaunch)
            }

            Section {
                Toggle("Show count on dock icon",  isOn: $prefs.notifyDockBadge)
                Toggle("Show count in menu bar",   isOn: $prefs.notifyMenuBarLabel)
                Toggle("Post system notification", isOn: $prefs.notifySystemBanner)
            } header: {
                Text("Notification style")
            } footer: {
                Text("Choose how Steading tells you updates are pending.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 8)
    }
}

#Preview {
    PreferencesView()
        .environment(PreferencesStore())
}

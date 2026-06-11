import SwiftUI

struct SettingsView: View {
    @AppStorage("conjet.automaticUpdatesEnabled") private var automaticUpdatesEnabled = true
    @AppStorage("conjet.showMenuBarIcon") private var showMenuBarIcon = true

    private var hideMenuBarIcon: Binding<Bool> {
        Binding(
            get: { !showMenuBarIcon },
            set: { showMenuBarIcon = !$0 }
        )
    }

    var body: some View {
        Form {
            Toggle("Enable automatic updates", isOn: $automaticUpdatesEnabled)
            Toggle("Hide menu bar icon", isOn: hideMenuBarIcon)
        }
        .padding(20)
        .frame(width: 380)
    }
}

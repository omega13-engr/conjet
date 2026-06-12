import SwiftUI

struct SettingsView: View {
    @AppStorage("conjet.automaticUpdatesEnabled") private var automaticUpdatesEnabled = true
    @AppStorage("conjet.showMenuBarIcon") private var showMenuBarIcon = true
    @StateObject private var backgroundService = ConjetBackgroundService.shared

    private var hideMenuBarIcon: Binding<Bool> {
        Binding(
            get: { !showMenuBarIcon },
            set: { showMenuBarIcon = !$0 }
        )
    }

    private var backgroundEnabled: Binding<Bool> {
        Binding(
            get: { backgroundService.wantsBackgroundMenuBar },
            set: { backgroundService.setBackgroundMenuBarEnabled($0) }
        )
    }

    var body: some View {
        Form {
            Toggle("Enable automatic updates", isOn: $automaticUpdatesEnabled)
            Toggle("Launch menu bar at login", isOn: backgroundEnabled)
            Toggle("Hide menu bar icon", isOn: hideMenuBarIcon)

            HStack {
                Text("Background Activity")
                Spacer()
                Text(backgroundService.status.title)
                    .foregroundStyle(statusColor)
            }

            if backgroundService.status == .requiresApproval {
                Button("Open Login Items") {
                    backgroundService.openLoginItemsSettings()
                }
            }

            if let error = backgroundService.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            backgroundService.refresh()
        }
    }

    private var statusColor: Color {
        switch backgroundService.status {
        case .enabled:
            .green
        case .requiresApproval:
            .orange
        case .notFound, .unknown:
            .red
        case .notRegistered:
            .secondary
        }
    }
}

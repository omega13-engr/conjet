import ConjetCore
import ServiceManagement
import SwiftUI

struct PrivilegedPortAuthorizationView: View {
    @EnvironmentObject private var app: ConjetAppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var status = SMAppService.daemon(plistName: PrivilegedPortService.plistName).status
    @State private var errorMessage: String?

    private var signedBuild: Bool { (try? PrivilegedPortService.signingTeam()) != nil }
    private var isMenuBarHelper: Bool { Bundle.main.bundleIdentifier == ConjetBundleIdentifiers.menuBarLoginItem }

    var body: some View {
        AppCard("Privileged Ports") {
            VStack(alignment: .leading, spacing: 8) {
                Text(statusMessage).font(.callout)
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack {
                    if isMenuBarHelper {
                        Button("Open Main Conjet App") { openMainApp() }
                    } else if status == .enabled {
                        Button("Repair Port Publishing") { Task { await app.repairNetwork() } }
                        Button("Remove Authorization") { unregister() }
                    } else if status == .requiresApproval {
                        Button("Open macOS Login Items") { SMAppService.openSystemSettingsLoginItems() }
                        Button("Check Authorization") { refreshStatus() }
                    } else {
                        Button("Authorize Port Helper") { register() }.disabled(!signedBuild)
                    }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshStatus() }
        }
    }

    private var statusMessage: String {
        if isMenuBarHelper { return "Manage privileged port authorization in the main Conjet app's Network page. Port forwarding also works from the menu bar runtime after authorization." }
        guard signedBuild else { return "Ports below 1024 require a Developer ID signed Conjet release for persistent authorization. This build can use an existing sudo authorization." }
        switch status {
        case .enabled: return "Authorized. Conjet can publish TCP and UDP ports below 1024."
        case .requiresApproval: return "Approve Conjet in macOS Login Items, then repair port publishing."
        case .notRegistered, .notFound: return "Authorize the Conjet helper to publish ports such as 80 and 443. macOS will request administrator approval."
        @unknown default: return "Port helper status is unavailable."
        }
    }

    private func openMainApp() {
        var url = Bundle.main.bundleURL
        for _ in 0..<4 { url.deleteLastPathComponent() }
        guard Bundle(url: url)?.bundleIdentifier == ConjetBundleIdentifiers.app else {
            errorMessage = "The enclosing Conjet app could not be found. Open Conjet from Applications."
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func refreshStatus() {
        status = SMAppService.daemon(plistName: PrivilegedPortService.plistName).status
    }

    private func register() {
        do {
            try SMAppService.daemon(plistName: PrivilegedPortService.plistName).register()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
        refreshStatus()
        if status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    private func unregister() {
        do {
            try SMAppService.daemon(plistName: PrivilegedPortService.plistName).unregister()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
        refreshStatus()
    }
}

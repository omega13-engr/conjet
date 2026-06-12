import Foundation
import ServiceManagement

enum ConjetBundleIdentifiers {
    static let app = "dev.conjet.app"
    static let menuBarLoginItem = "dev.conjet.app.menubar"
}

enum ConjetBackgroundItemStatus: String {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown

    var title: String {
        switch self {
        case .notRegistered: "Off"
        case .enabled: "On"
        case .requiresApproval: "Needs Approval"
        case .notFound: "Missing"
        case .unknown: "Unknown"
        }
    }
}

@MainActor
final class ConjetBackgroundService: ObservableObject {
    static let shared = ConjetBackgroundService()
    static let enabledPreferenceKey = "conjet.backgroundMenuBarEnabled"
    private static let disableRegistrationEnvironmentKey = "CONJET_DISABLE_BACKGROUND_SERVICE_REGISTRATION"

    @Published private(set) var status: ConjetBackgroundItemStatus
    @Published private(set) var lastError: String?

    private var loginItem: SMAppService {
        SMAppService.loginItem(identifier: ConjetBundleIdentifiers.menuBarLoginItem)
    }

    private init() {
        self.status = Self.currentStatus()
    }

    var isRunningAsMenuBarLoginItem: Bool {
        Bundle.main.bundleIdentifier == ConjetBundleIdentifiers.menuBarLoginItem
    }

    var wantsBackgroundMenuBar: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Self.enabledPreferenceKey) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: Self.enabledPreferenceKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledPreferenceKey)
        }
    }

    var foregroundAppShouldDeferMenuBarIcon: Bool {
        !isRunningAsMenuBarLoginItem && wantsBackgroundMenuBar && status == .enabled
    }

    func reconcileOnLaunch() {
        refresh()
        guard ProcessInfo.processInfo.environment[Self.disableRegistrationEnvironmentKey] != "1",
              !isRunningAsMenuBarLoginItem,
              wantsBackgroundMenuBar else { return }
        register()
    }

    func setBackgroundMenuBarEnabled(_ enabled: Bool) {
        wantsBackgroundMenuBar = enabled
        if enabled {
            register()
        } else {
            unregister()
        }
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
    }

    func refresh() {
        status = Self.currentStatus()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func register() {
        refresh()
        guard status != .enabled, status != .requiresApproval else {
            lastError = nil
            return
        }

        do {
            try loginItem.register()
            lastError = nil
        } catch {
            lastError = Self.compactError(error)
        }
        refresh()
    }

    private func unregister() {
        refresh()
        guard status == .enabled || status == .requiresApproval else {
            lastError = nil
            return
        }

        do {
            try loginItem.unregister()
            lastError = nil
        } catch {
            lastError = Self.compactError(error)
        }
        refresh()
    }

    private static func currentStatus() -> ConjetBackgroundItemStatus {
        switch SMAppService.loginItem(identifier: ConjetBundleIdentifiers.menuBarLoginItem).status {
        case .notRegistered:
            return .notRegistered
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .unknown
        }
    }

    private static func compactError(_ error: Error) -> String {
        let nsError = error as NSError
        let message = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "\(nsError.domain) \(nsError.code)" : message
    }
}

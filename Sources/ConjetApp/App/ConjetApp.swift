import AppKit
import SwiftUI

@main
@MainActor
final class ConjetDesktopApp: NSObject, NSApplicationDelegate {
    private static var sharedDelegate: ConjetDesktopApp?

    private let state = ConjetAppState()
    private lazy var statusMenuController = ConjetStatusMenuController(app: state)
    private var settingsWindow: NSWindow?

    static func main() {
        let application = NSApplication.shared
        let delegate = ConjetDesktopApp()
        sharedDelegate = delegate
        application.delegate = delegate
        application.run()
    }

    override init() {
        super.init()
        ConjetWindowPresenter.configure(app: state)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        installMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ConjetBackgroundService.shared.reconcileOnLaunch()
        state.startAutoRefresh()
        statusMenuController.install()

        if ConjetLaunchOptions.startsInMenuBarOnlyMode {
            NSApp.setActivationPolicy(.accessory)
            return
        }

        NSApp.setActivationPolicy(.regular)
        ConjetWindowPresenter.presentMainWindow(app: state)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ConjetWindowPresenter.presentMainWindow(app: state)
        return false
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu(title: "Conjet")
        appMenuItem.submenu = appMenu

        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)

        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Conjet",
            action: #selector(quitConjet),
            keyEquivalent: "q"
        )
        quitItem.target = self
        appMenu.addItem(quitItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Conjet Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 440, height: 240))
        window.minSize = NSSize(width: 440, height: 240)
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitConjet() {
        statusMenuController.disable()
        Task {
            await state.stopForQuit()
            await MainActor.run {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

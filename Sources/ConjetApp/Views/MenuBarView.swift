import AppKit
import Combine
import ConjetCore
import OSLog
import SwiftUI

private let windowLogger = Logger(subsystem: "dev.conjet.app", category: "Windowing")

enum ConjetLaunchOptions {
    static let menuBarOnlyArgument = "--background-menu-bar"

    static var startsInMenuBarOnlyMode: Bool {
        CommandLine.arguments.contains(menuBarOnlyArgument)
    }
}

struct ConjetMenuBarCommands: View {
    @ObservedObject var app: ConjetAppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open") {
            ConjetWindowPresenter.presentMainWindow(app: app) {
                openWindow(id: "main")
            }
        }

        Divider()

        Button("Quit") {
            Task {
                await app.stopForQuit()
                await MainActor.run {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }
}

struct ConjetMenuBarIconLabel: View {
    @ObservedObject var app: ConjetAppState

    private var vmState: VMRunState? {
        app.snapshot.daemonResponse?.status?.vm?.state ?? app.snapshot.daemonResponse?.vm?.state
    }

    private var isAnimating: Bool {
        vmState == .starting || vmState == .stopping
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.32)) { context in
            let image = MenuBarIconAsset.image()
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: image.size.width, height: image.size.height)
                .opacity(opacity(at: context.date))
                .accessibilityLabel("Conjet")
        }
        .onAppear {
            ConjetWindowPresenter.configure(app: app)
            app.startAutoRefresh()
        }
    }

    private func opacity(at date: Date) -> Double {
        guard isAnimating else { return 1 }
        let phase = Int(date.timeIntervalSinceReferenceDate / 0.32)
        return phase.isMultiple(of: 2) ? 1 : 0.52
    }
}

@MainActor
enum ConjetWindowPresenter {
    private static var appState: ConjetAppState?
    private static var ownedWindow: NSWindow?

    static func configure(app: ConjetAppState) {
        appState = app
        windowLogger.debug("configured window presenter")
    }

    static func presentMainWindow(app: ConjetAppState? = nil, openWindow: (() -> Void)? = nil) {
        if let app {
            configure(app: app)
        }
        windowLogger.info("present main window requested hasState=\((app ?? appState) != nil, privacy: .public) windowCount=\(NSApp.windows.count, privacy: .public)")
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        if focusExistingMainWindow() {
            windowLogger.info("focused existing main window")
            activate()
            return
        }

        if let app = app ?? appState {
            windowLogger.info("creating owned main window")
            showOwnedWindow(app: app)
            activate()
            return
        }

        windowLogger.error("could not present main window because no app state was available")
        openWindow?()
        Task { @MainActor in
            _ = focusExistingMainWindow()
            activate()
        }
    }

    @discardableResult
    private static func focusExistingMainWindow() -> Bool {
        if let ownedWindow {
            show(window: ownedWindow)
            return isVisibleMainWindow(ownedWindow)
        }
        return false
    }

    private static func activate() {
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func showOwnedWindow(app: ConjetAppState) {
        let rootView = ContentView()
            .environmentObject(app)
            .frame(minWidth: 1080, minHeight: 720)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Conjet"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.managed, .fullScreenPrimary]
        window.setContentSize(NSSize(width: 1080, height: 720))
        window.minSize = NSSize(width: 1080, height: 720)
        window.isReleasedWhenClosed = false
        window.center()
        ownedWindow = window
        show(window: window)
    }

    private static func show(window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }

    private static func isVisibleMainWindow(_ window: NSWindow) -> Bool {
        window.isVisible && window.frame.width > 0 && window.frame.height > 0
    }
}

@MainActor
final class ConjetStatusMenuController: NSObject {
    private let app: ConjetAppState
    private var statusItem: NSStatusItem?
    private var animationTimer: Timer?
    private var snapshotObserver: AnyCancellable?
    private var defaultsObserver: NSObjectProtocol?
    private var animationPhase = false
    private var isDisabled = false

    init(app: ConjetAppState) {
        self.app = app
        super.init()
    }

    func install() {
        isDisabled = false
        installObservers()
        syncVisibility()
    }

    func disable() {
        isDisabled = true
        removeObservers()
        removeStatusItem()
    }

    private func installObservers() {
        if snapshotObserver == nil {
            snapshotObserver = app.$snapshot.sink { [weak self] _ in
                Task { @MainActor in
                    self?.syncVisibility()
                }
            }
        }

        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncVisibility()
            }
        }
    }

    private func removeObservers() {
        snapshotObserver?.cancel()
        snapshotObserver = nil
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
            self.defaultsObserver = nil
        }
    }

    private func syncVisibility() {
        guard !isDisabled, shouldShowMenuBarIcon else {
            removeStatusItem()
            return
        }
        if statusItem == nil {
            installStatusItem()
        }
        updateAnimation()
    }

    private var shouldShowMenuBarIcon: Bool {
        if UserDefaults.standard.object(forKey: "conjet.showMenuBarIcon") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "conjet.showMenuBarIcon")
    }

    private var vmState: VMRunState? {
        app.snapshot.daemonResponse?.status?.vm?.state ?? app.snapshot.daemonResponse?.vm?.state
    }

    private var shouldAnimate: Bool {
        vmState == .starting || vmState == .stopping
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = makeMenu()
        statusItem = item
        updateIcon(opacity: 1)
    }

    private func removeStatusItem() {
        animationTimer?.invalidate()
        animationTimer = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Conjet")

        let openItem = NSMenuItem(title: "Open", action: #selector(openConjet), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitConjet), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private func updateAnimation() {
        guard shouldAnimate else {
            animationTimer?.invalidate()
            animationTimer = nil
            updateIcon(opacity: 1)
            return
        }

        guard animationTimer == nil else { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.32, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.animationPhase.toggle()
                self.updateIcon(opacity: self.animationPhase ? 1 : 0.52)
            }
        }
    }

    private func updateIcon(opacity: Double) {
        guard let button = statusItem?.button else { return }
        let image = MenuBarIconAsset.image()
        image.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        button.toolTip = "Conjet"
        button.alphaValue = opacity
        statusItem?.length = MenuBarIconMetrics.statusItemLength(for: image)
    }

    @objc private func openConjet() {
        ConjetWindowPresenter.presentMainWindow(app: app)
    }

    @objc private func quitConjet() {
        disable()
        Task {
            await app.stopForQuit()
            await MainActor.run {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

private enum MenuBarIconMetrics {
    private static let maximumCanvasHeight: CGFloat = 22
    private static let displayCanvasHeight: CGFloat = 18
    private static let horizontalPadding: CGFloat = 6

    static func pointSize(for image: NSImage) -> NSSize {
        let height = min(displayCanvasHeight, maximumCanvasHeight)
        return NSSize(width: ceil(height * pixelAspectRatio(for: image)), height: height)
    }

    static func statusItemLength(for image: NSImage) -> CGFloat {
        image.size.width + horizontalPadding
    }

    private static func pixelAspectRatio(for image: NSImage) -> CGFloat {
        if let representation = image.representations.first, representation.pixelsHigh > 0 {
            return CGFloat(representation.pixelsWide) / CGFloat(representation.pixelsHigh)
        }
        guard image.size.height > 0 else { return 1 }
        return image.size.width / image.size.height
    }
}

private enum MenuBarIconAsset {
    static func image() -> NSImage {
        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("MenuBarIcon.png"),
           let image = NSImage(contentsOf: resourceURL) {
            return prepare(image)
        }

        if let packageURL = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "png"),
           let image = NSImage(contentsOf: packageURL) {
            return prepare(image)
        }

        if let image = NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: "Conjet") {
            return prepare(image)
        }

        return NSImage(size: NSSize(width: 18, height: 18))
    }

    private static func prepare(_ image: NSImage) -> NSImage {
        image.isTemplate = true
        image.size = MenuBarIconMetrics.pointSize(for: image)
        return image
    }
}

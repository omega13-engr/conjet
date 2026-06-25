import AppKit
import Combine
import ConjetCore
import OSLog
import QuartzCore
import SwiftUI

private let windowLogger = Logger(subsystem: "dev.conjet.app", category: "Windowing")

private enum MenuBarIconAnimation {
    static let interval: TimeInterval = 0.48
    static let duration: TimeInterval = 0.36
    static let dimOpacity = 0.48
}

enum ConjetLaunchOptions {
    static let menuBarOnlyArgument = "--background-menu-bar"

    static var startsInMenuBarOnlyMode: Bool {
        CommandLine.arguments.contains(menuBarOnlyArgument)
            || Bundle.main.bundleIdentifier == ConjetBundleIdentifiers.menuBarLoginItem
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
            NSApplication.shared.terminate(nil)
        }
    }
}

struct ConjetMenuBarIconLabel: View {
    @ObservedObject var app: ConjetAppState

    private var vmState: VMRunState? {
        app.currentVMState
    }

    private var isAnimating: Bool {
        vmState == .starting || vmState == .stopping
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: MenuBarIconAnimation.interval)) { context in
            let image = MenuBarIconAsset.image()
            let opacity = opacity(at: context.date)
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: image.size.width, height: image.size.height)
                .opacity(opacity)
                .animation(.easeInOut(duration: MenuBarIconAnimation.duration), value: opacity)
                .accessibilityLabel("Conjet")
        }
        .onAppear {
            ConjetWindowPresenter.configure(app: app)
            app.startAutoRefresh()
        }
    }

    private func opacity(at date: Date) -> Double {
        guard isAnimating else { return 1 }
        let phase = Int(date.timeIntervalSinceReferenceDate / MenuBarIconAnimation.interval)
        return phase.isMultiple(of: 2) ? 1 : MenuBarIconAnimation.dimOpacity
    }
}

@MainActor
enum ConjetWindowPresenter {
    private static var appState: ConjetAppState?
    private static var ownedWindow: NSWindow?
    private static var ownedWindowDelegate: ConjetMainWindowDelegate?

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
        let delegate = ConjetMainWindowDelegate(app: app)
        window.delegate = delegate
        ownedWindowDelegate = delegate
        window.center()
        ownedWindow = window
        show(window: window)
    }

    private static func show(window: NSWindow) {
        appState?.setInteractiveSurfaceVisible(true)
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
private final class ConjetMainWindowDelegate: NSObject, NSWindowDelegate {
    private weak var app: ConjetAppState?

    init(app: ConjetAppState) {
        self.app = app
    }

    func windowDidBecomeMain(_ notification: Notification) {
        app?.setInteractiveSurfaceVisible(true)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        app?.setInteractiveSurfaceVisible(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        app?.setInteractiveSurfaceVisible(true)
    }

    func windowWillClose(_ notification: Notification) {
        app?.setInteractiveSurfaceVisible(false)
    }
}

@MainActor
final class ConjetStatusMenuController: NSObject {
    private let app: ConjetAppState
    private var statusItem: NSStatusItem?
    private var animationTimer: Timer?
    private var snapshotObserver: AnyCancellable?
    private var commandObserver: AnyCancellable?
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

        if commandObserver == nil {
            commandObserver = app.$commandVMState.sink { [weak self] _ in
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
        commandObserver?.cancel()
        commandObserver = nil
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
            return ConjetLaunchOptions.startsInMenuBarOnlyMode
                || !ConjetBackgroundService.shared.foregroundAppShouldDeferMenuBarIcon
        }
        guard UserDefaults.standard.bool(forKey: "conjet.showMenuBarIcon") else {
            return false
        }
        return ConjetLaunchOptions.startsInMenuBarOnlyMode
            || !ConjetBackgroundService.shared.foregroundAppShouldDeferMenuBarIcon
    }

    private var vmState: VMRunState? {
        app.currentVMState
    }

    private var shouldAnimate: Bool {
        vmState == .starting || vmState == .stopping
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = makeMenu()
        statusItem = item
        updateIcon(opacity: 1, animated: false)
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
            stopBlinkAnimation()
            return
        }

        guard animationTimer == nil else { return }
        animationPhase = false
        updateIcon(opacity: 1, animated: false)
        pulseIcon()
        let timer = Timer(timeInterval: MenuBarIconAnimation.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pulseIcon()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stopBlinkAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationPhase = false
        updateIcon(opacity: 1, animated: false)
    }

    private func pulseIcon() {
        animationPhase.toggle()
        let opacity = animationPhase ? MenuBarIconAnimation.dimOpacity : 1
        updateIcon(opacity: opacity, animated: true)
    }

    private func updateIcon(opacity: Double, animated: Bool) {
        guard let button = statusItem?.button else { return }
        if button.image == nil {
            let image = MenuBarIconAsset.image()
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.toolTip = "Conjet"
            button.wantsLayer = true
            statusItem?.length = MenuBarIconMetrics.statusItemLength(for: image)
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = MenuBarIconAnimation.duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                button.animator().alphaValue = opacity
            }
        } else {
            button.layer?.removeAllAnimations()
            button.alphaValue = opacity
        }
    }

    @objc private func openConjet() {
        ConjetWindowPresenter.presentMainWindow(app: app)
    }

    @objc private func quitConjet() {
        NSApplication.shared.terminate(nil)
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

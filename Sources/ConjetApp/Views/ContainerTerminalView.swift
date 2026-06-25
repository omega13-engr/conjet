import AppKit
import ConjetAppCore
import SwiftTerm
import SwiftUI

struct ContainerTerminalTheme {
    var foreground = NSColor(calibratedRed: 0.86, green: 0.89, blue: 0.92, alpha: 1.0)
    var background = NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.09, alpha: 1.0)
    var cursor = NSColor(calibratedRed: 0.31, green: 0.82, blue: 0.45, alpha: 1.0)
    var cursorText = NSColor.black
    var selection = NSColor.systemBlue.withAlphaComponent(0.28)
    var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
}

struct ContainerTerminalView: NSViewRepresentable {
    let command: DockerTerminalCommand
    var theme = ContainerTerminalTheme()
    var onExit: @MainActor @Sendable (Int32?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(onExit: onExit)
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.processDelegate = context.coordinator
        configure(terminal)
        terminal.startProcess(
            executable: command.executable,
            args: command.arguments,
            environment: command.environment
        )
        return terminal
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        context.coordinator.onExit = onExit
        configure(nsView)
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        nsView.terminate()
    }

    private func configure(_ terminal: LocalProcessTerminalView) {
        terminal.wantsLayer = true
        terminal.nativeForegroundColor = theme.foreground
        terminal.nativeBackgroundColor = theme.background
        terminal.layer?.backgroundColor = theme.background.cgColor
        terminal.caretColor = theme.cursor
        terminal.caretTextColor = theme.cursorText
        terminal.selectedTextBackgroundColor = theme.selection
        terminal.font = theme.font
        terminal.optionAsMetaKey = true
        terminal.allowMouseReporting = true
        terminal.getTerminal().setCursorStyle(.steadyBlock)
        try? terminal.setUseMetal(false)
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var onExit: @MainActor @Sendable (Int32?) -> Void

        init(onExit: @escaping @MainActor @Sendable (Int32?) -> Void) {
            self.onExit = onExit
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            let onExit = self.onExit
            Task { @MainActor in
                onExit(exitCode)
            }
        }
    }
}

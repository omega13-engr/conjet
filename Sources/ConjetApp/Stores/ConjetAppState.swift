import ConjetAppCore
import ConjetCore
import Foundation
import SwiftUI

enum ManagementSection: String, CaseIterable, Identifiable {
    case overview
    case containers
    case compose
    case machines
    case images
    case volumes
    case activity
    case network
    case processes
    case commands

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .containers: "Containers"
        case .compose: "Compose"
        case .machines: "Machines"
        case .images: "Images"
        case .volumes: "Volumes"
        case .activity: "Activity Monitor"
        case .network: "Network"
        case .processes: "Processes"
        case .commands: "Commands"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"
        case .containers: "shippingbox"
        case .compose: "square.stack.3d.up"
        case .machines: "desktopcomputer"
        case .images: "opticaldiscdrive"
        case .volumes: "externaldrive"
        case .activity: "waveform.path.ecg"
        case .network: "network"
        case .processes: "terminal"
        case .commands: "list.bullet.rectangle"
        }
    }
}

@MainActor
final class ConjetAppState: ObservableObject {
    @Published var selectedSection: ManagementSection = .overview
    @Published var snapshot: DashboardSnapshot
    @Published var commandLog: [CommandLogEntry] = []
    @Published var isRefreshing = false
    @Published var activeCommandLabel: String?
    @Published var selectedContainerID: String?
    @Published var selectedImageID: String?
    @Published var selectedVolumeID: String?
    @Published var runImage = "hello-world"
    @Published var runCommand = ""
    @Published var pullImage = "ubuntu:24.04"
    @Published var composeDirectory = FileManager.default.currentDirectoryPath
    @Published var composeArguments = "--detach"
    @Published var selectedBindPolicy: ConjetNetworkBindPolicy = .secureLocal
    @Published var selectedBridgeEngine: ConjetNetworkBridgeEngine = .auto

    private let service: ConjetManagementService
    private var refreshTask: Task<Void, Never>?

    init(service: ConjetManagementService = ConjetManagementService()) {
        self.service = service
        self.snapshot = DashboardSnapshot.empty()
    }

    deinit {
        refreshTask?.cancel()
    }

    var selectedContainer: DockerContainer? {
        snapshot.containers.first { $0.id == selectedContainerID } ?? snapshot.containers.first
    }

    var selectedImage: DockerImage? {
        snapshot.images.first { $0.id == selectedImageID } ?? snapshot.images.first
    }

    var selectedVolume: DockerVolume? {
        snapshot.volumes.first { $0.id == selectedVolumeID } ?? snapshot.volumes.first
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let latest = await service.loadSnapshot()
        snapshot = latest
        selectedBindPolicy = latest.daemonResponse?.status?.network?.bindPolicy ?? selectedBindPolicy
        if let bridge = latest.daemonResponse?.status?.network?.requestedBridgeEngine
            .flatMap(ConjetNetworkBridgeEngine.init(rawValue:)) {
            selectedBridgeEngine = bridge
        }
        if selectedContainerID == nil {
            selectedContainerID = latest.containers.first?.id
        }
        if selectedImageID == nil {
            selectedImageID = latest.images.first?.id
        }
        if selectedVolumeID == nil {
            selectedVolumeID = latest.volumes.first?.id
        }
        isRefreshing = false
    }

    func startAutoRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func startRuntime() async {
        await runAndRefresh(label: "Start Conjet") {
            await service.runConjet(["start"], label: "Start Conjet", timeoutSeconds: nil)
        }
    }

    func stopRuntime() async {
        await runAndRefresh(label: "Stop Conjet") {
            await service.runConjet(["stop"], label: "Stop Conjet", timeoutSeconds: 60)
        }
    }

    func stopForQuit() async {
        activeCommandLabel = "Quit Conjet"
        let entry = await service.runConjet(["stop"], label: "Quit Conjet", timeoutSeconds: 90)
        commandLog.insert(entry, at: 0)
        commandLog = Array(commandLog.prefix(80))
        activeCommandLabel = nil
    }

    func restartRuntime() async {
        await runAndRefresh(label: "Restart Conjet") {
            await service.runConjet(["restart"], label: "Restart Conjet", timeoutSeconds: nil)
        }
    }

    func updateRuntime() async {
        await runAndRefresh(label: "Update Conjet Core") {
            await service.runConjet(["update", "--restart"], label: "Update Conjet Core", timeoutSeconds: nil)
        }
    }

    func runContainer() async {
        let args = [runImage].filter { !$0.isEmpty } + splitArguments(runCommand)
        guard !args.isEmpty else { return }
        await runAndRefresh(label: "Run Container") {
            await service.runConjet(["run"] + args, label: "Run Container", timeoutSeconds: nil)
        }
    }

    func containerAction(_ action: String, container: DockerContainer) async {
        let label = "\(action.capitalized) \(container.name)"
        let args: [String]
        switch action {
        case "remove":
            args = ["rm", "-f", container.id]
        default:
            args = [action, container.id]
        }
        await runAndRefresh(label: label) {
            await service.runDocker(args, label: label, timeoutSeconds: 60)
        }
    }

    func pullImageAction() async {
        let image = pullImage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !image.isEmpty else { return }
        await runAndRefresh(label: "Pull \(image)") {
            await service.runDocker(["pull", image], label: "Pull \(image)", timeoutSeconds: nil)
        }
    }

    func removeImage(_ image: DockerImage) async {
        await runAndRefresh(label: "Remove \(image.reference)") {
            await service.runDocker(["rmi", image.reference], label: "Remove \(image.reference)", timeoutSeconds: 120)
        }
    }

    func removeVolume(_ volume: DockerVolume) async {
        await runAndRefresh(label: "Remove volume \(volume.name)") {
            await service.runDocker(["volume", "rm", volume.name], label: "Remove volume \(volume.name)", timeoutSeconds: 60)
        }
    }

    func pruneVolumes() async {
        await runAndRefresh(label: "Prune volumes") {
            await service.runDocker(["volume", "prune", "--force"], label: "Prune volumes", timeoutSeconds: 120)
        }
    }

    func compose(_ action: String) async {
        let directory = URL(fileURLWithPath: composeDirectory, isDirectory: true)
        let args: [String]
        switch action {
        case "up":
            args = ["up"] + splitArguments(composeArguments)
        case "down":
            args = ["down"]
        case "ps":
            args = ["ps"]
        case "logs":
            args = ["logs", "--tail", "120"]
        default:
            return
        }
        await runAndRefresh(label: "Compose \(action)") {
            await service.runCompose(args, workingDirectory: directory, label: "Compose \(action)")
        }
    }

    func vm(_ action: String) async {
        let args: [String]
        switch action {
        case "start": args = ["vm", "start"]
        case "stop": args = ["vm", "stop"]
        case "status": args = ["vm", "status", "--json"]
        case "logs": args = ["vm", "logs", "--lines", "200"]
        case "fetchCore": args = ["vm", "fetch-conjet-core", "--force"]
        default: return
        }
        await runAndRefresh(label: "VM \(action)") {
            await service.runConjet(args, label: "VM \(action)", timeoutSeconds: action == "logs" ? 30 : nil)
        }
    }

    func repairNetwork() async {
        await runAndRefresh(label: "Repair network") {
            await service.runConjet(["network", "repair"], label: "Repair network", timeoutSeconds: 60)
        }
    }

    func bridgeTest() async {
        await runAndRefresh(label: "Network bridge test") {
            await service.runConjet(["network", "bridge-test"], label: "Network bridge test", timeoutSeconds: 60)
        }
    }

    func applyNetworkPolicy() async {
        await runAndRefresh(label: "Set network policy") {
            await service.runConjet(
                ["network", "policy", "set", selectedBindPolicy.rawValue],
                label: "Set network policy",
                timeoutSeconds: 30
            )
        }
        guard selectedBridgeEngine != .auto else { return }
        await runAndRefresh(label: "Switch bridge engine") {
            await service.runConjet(
                ["network", "bridge-switch", selectedBridgeEngine.rawValue, "--restart"],
                label: "Switch bridge engine",
                timeoutSeconds: nil
            )
        }
    }

    func clearCommandLog() {
        commandLog.removeAll()
    }

    private func runAndRefresh(label: String, operation: () async -> CommandLogEntry) async {
        activeCommandLabel = label
        let entry = await operation()
        commandLog.insert(entry, at: 0)
        commandLog = Array(commandLog.prefix(80))
        activeCommandLabel = nil
        await refresh()
    }

    private func splitArguments(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

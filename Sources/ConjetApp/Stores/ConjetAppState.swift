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

enum RuntimeHealthState: Equatable {
    case online
    case degraded
    case transitioning
    case offline
}

struct RuntimeHealth: Equatable {
    var state: RuntimeHealthState
    var value: String
    var detail: String
    var subtitle: String?

    var isReachable: Bool {
        state == .online || state == .degraded || state == .transitioning
    }
}

@MainActor
final class ConjetAppState: ObservableObject {
    @Published var selectedSection: ManagementSection = .overview
    @Published var snapshot: DashboardSnapshot
    @Published var commandLog: [CommandLogEntry] = []
    @Published var isRefreshing = false
    @Published var activeCommandLabel: String?
    @Published private(set) var commandVMState: VMRunState?
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
    private var transitionRefreshTask: Task<Void, Never>?
    private var fastRefreshUntil = Date.distantPast

    private static let transitionRefreshDelayNanoseconds: UInt64 = 250_000_000
    private static let fastRefreshDelayNanoseconds: UInt64 = 350_000_000
    private static let normalRefreshDelayNanoseconds: UInt64 = 2_000_000_000
    private static let launchFastRefreshDuration: TimeInterval = 12
    private static let commandFastRefreshDuration: TimeInterval = 20

    init(service: ConjetManagementService = ConjetManagementService()) {
        self.service = service
        self.snapshot = DashboardSnapshot.empty()
    }

    deinit {
        refreshTask?.cancel()
        transitionRefreshTask?.cancel()
    }

    var selectedContainer: DockerContainer? {
        snapshot.containers.first { $0.id == selectedContainerID } ?? snapshot.containers.first
    }

    var selectedImage: DockerImage? {
        snapshot.images.first { Self.imageSelectionMatches($0, selectedImageID) } ?? snapshot.images.first
    }

    var selectedVolume: DockerVolume? {
        snapshot.volumes.first { $0.id == selectedVolumeID } ?? snapshot.volumes.first
    }

    var currentVMState: VMRunState? {
        Self.resolvedVMState(command: commandVMState, snapshot: snapshotVMState)
    }

    var displayedVMStatus: VMRuntimeStatus? {
        Self.vmStatus(command: commandVMState, snapshot: snapshot)
    }

    var runtimeHealth: RuntimeHealth {
        Self.runtimeHealth(command: commandVMState, snapshot: snapshot)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let latest = await service.loadSnapshot()
        completeCommandTransitionIfNeeded(actual: Self.vmState(from: latest))
        snapshot = latest
        selectedBindPolicy = latest.daemonResponse?.status?.network?.bindPolicy ?? selectedBindPolicy
        if let bridge = latest.daemonResponse?.status?.network?.requestedBridgeEngine
            .flatMap(ConjetNetworkBridgeEngine.init(rawValue:)) {
            selectedBridgeEngine = bridge
        }
        if selectedContainerID == nil {
            selectedContainerID = latest.containers.first?.id
        }
        if selectedImageID == nil || !latest.images.contains(where: { Self.imageSelectionMatches($0, selectedImageID) }) {
            selectedImageID = latest.images.first?.selectionID
        }
        if selectedVolumeID == nil {
            selectedVolumeID = latest.volumes.first?.id
        }
        isRefreshing = false
    }

    func startAutoRefresh() {
        prioritizeRefresh(for: Self.launchFastRefreshDuration)
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(nanoseconds: self.autoRefreshDelayNanoseconds)
            }
        }
    }

    private var autoRefreshDelayNanoseconds: UInt64 {
        if Date() < fastRefreshUntil {
            return Self.fastRefreshDelayNanoseconds
        }
        switch currentVMState {
        case .starting, .stopping:
            return Self.fastRefreshDelayNanoseconds
        default:
            return Self.normalRefreshDelayNanoseconds
        }
    }

    func startRuntime() async {
        await runAndRefresh(label: "Start Conjet", vmTransition: .starting) {
            await service.runConjet(["start", "--json"], label: "Start Conjet", timeoutSeconds: nil)
        }
    }

    func stopRuntime() async {
        await runAndRefresh(label: "Stop Conjet", vmTransition: .stopping) {
            await service.runConjet(["stop", "--json"], label: "Stop Conjet", timeoutSeconds: 60)
        }
    }

    func stopForQuit() async {
        activeCommandLabel = "Quit Conjet"
        setCommandVMState(.stopping)
        prioritizeRefresh(for: Self.commandFastRefreshDuration)
        let entry = await service.runConjet(["stop"], label: "Quit Conjet", timeoutSeconds: 90)
        commandLog.insert(entry, at: 0)
        commandLog = Array(commandLog.prefix(80))
        activeCommandLabel = nil
        setCommandVMState(nil)
    }

    func restartRuntime() async {
        await runAndRefresh(label: "Restart Conjet", vmTransition: .starting) {
            await service.runConjet(["restart", "--json"], label: "Restart Conjet", timeoutSeconds: nil)
        }
    }

    func updateRuntime() async {
        await runAndRefresh(label: "Update Conjet Core", vmTransition: .starting) {
            await service.runConjet(["update", "--restart", "--json"], label: "Update Conjet Core", timeoutSeconds: nil)
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
        let vmTransition: VMRunState?
        switch action {
        case "start":
            args = ["vm", "start", "--json"]
            vmTransition = .starting
        case "stop":
            args = ["vm", "stop", "--json"]
            vmTransition = .stopping
        case "status":
            args = ["vm", "status", "--json"]
            vmTransition = nil
        case "logs":
            args = ["vm", "logs", "--lines", "200"]
            vmTransition = nil
        case "fetchCore":
            args = ["vm", "fetch-conjet-core", "--force"]
            vmTransition = nil
        default: return
        }
        await runAndRefresh(label: "VM \(action)", vmTransition: vmTransition) {
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

    private func runAndRefresh(
        label: String,
        vmTransition: VMRunState? = nil,
        operation: () async -> CommandLogEntry
    ) async {
        activeCommandLabel = label
        if let vmTransition {
            setCommandVMState(vmTransition)
            prioritizeRefresh(for: Self.commandFastRefreshDuration)
        }
        let entry = await operation()
        commandLog.insert(entry, at: 0)
        commandLog = Array(commandLog.prefix(80))
        if let response = Self.daemonResponse(from: entry.stdout) {
            applyDaemonResponse(response)
        }
        activeCommandLabel = nil
        if vmTransition != nil {
            setCommandVMState(nil)
        }
        await refresh()
    }

    private func splitArguments(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private var snapshotVMState: VMRunState? {
        Self.vmState(from: snapshot)
    }

    private func prioritizeRefresh(for duration: TimeInterval) {
        fastRefreshUntil = max(fastRefreshUntil, Date().addingTimeInterval(duration))
    }

    private func applyDaemonResponse(_ response: DaemonResponse) {
        var latest = snapshot
        latest.daemonResponse = response
        completeCommandTransitionIfNeeded(actual: Self.vmState(from: latest))
        snapshot = latest
    }

    private func refreshTransitionVMStatus() async {
        guard let response = await service.loadVMStatus() else { return }
        applyDaemonResponse(response)
    }

    private func setCommandVMState(_ state: VMRunState?) {
        guard commandVMState != state else { return }
        commandVMState = state
        if state == nil {
            transitionRefreshTask?.cancel()
            transitionRefreshTask = nil
        } else {
            startTransitionRefresh()
        }
    }

    private func startTransitionRefresh() {
        transitionRefreshTask?.cancel()
        transitionRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshTransitionVMStatus()
                guard self.commandVMState != nil else { return }
                try? await Task.sleep(nanoseconds: Self.transitionRefreshDelayNanoseconds)
            }
        }
    }

    private func completeCommandTransitionIfNeeded(actual: VMRunState?) {
        guard let commandVMState,
              Self.isCommandTransitionComplete(command: commandVMState, actual: actual) else {
            return
        }
        fastRefreshUntil = Date()
        setCommandVMState(nil)
    }

    static func resolvedVMState(command: VMRunState?, snapshot: VMRunState?) -> VMRunState? {
        guard let command else { return snapshot }
        if isCommandTransitionComplete(command: command, actual: snapshot) {
            return snapshot
        }
        return command
    }

    static func isCommandTransitionComplete(command: VMRunState, actual: VMRunState?) -> Bool {
        switch (command, actual) {
        case (.starting, .running?), (.starting, .error?):
            true
        case (.stopping, .stopped?), (.stopping, .unconfigured?), (.stopping, .error?):
            true
        default:
            false
        }
    }

    static func runtimeHealth(command: VMRunState?, snapshot: DashboardSnapshot) -> RuntimeHealth {
        let actualVMState = vmState(from: snapshot)
        if let command, !isCommandTransitionComplete(command: command, actual: actualVMState) {
            return RuntimeHealth(
                state: .transitioning,
                value: command.rawValue,
                detail: "waiting for VM \(command.rawValue)",
                subtitle: snapshot.daemonResponse?.message
            )
        }

        if let response = snapshot.daemonResponse, response.ok {
            let value = response.status?.state.rawValue ?? actualVMState?.rawValue ?? "online"
            let detail = response.status.map { "pid \($0.pid)" }
                ?? response.vm?.dockerSocketPath
                ?? response.message
            return RuntimeHealth(
                state: .online,
                value: value,
                detail: detail,
                subtitle: response.message
            )
        }

        if snapshot.dockerReachable {
            let daemonMessage = snapshot.daemonResponse?.message.trimmingCharacters(in: .whitespacesAndNewlines)
            let subtitle = if let daemonMessage, !daemonMessage.isEmpty {
                "Docker is reachable; \(daemonMessage)"
            } else {
                "Docker is reachable at \(snapshot.dockerSocketPath)"
            }
            return RuntimeHealth(
                state: .degraded,
                value: "degraded",
                detail: "Docker socket reachable",
                subtitle: subtitle
            )
        }

        if snapshot.dockerSocketAvailable {
            let daemonMessage = snapshot.daemonResponse?.message.trimmingCharacters(in: .whitespacesAndNewlines)
            let subtitle = if let daemonMessage, !daemonMessage.isEmpty {
                "Docker socket exists; \(daemonMessage)"
            } else {
                "Docker socket exists but did not answer yet"
            }
            return RuntimeHealth(
                state: .degraded,
                value: "socket present",
                detail: snapshot.dockerSocketPath,
                subtitle: subtitle
            )
        }

        let message = snapshot.daemonResponse?.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return RuntimeHealth(
            state: .offline,
            value: "offline",
            detail: snapshot.dockerSocketPath.isEmpty ? "Docker socket unavailable" : snapshot.dockerSocketPath,
            subtitle: message?.isEmpty == false ? message : "Conjet runtime is not reachable"
        )
    }

    static func vmStatus(command: VMRunState?, snapshot: DashboardSnapshot) -> VMRuntimeStatus? {
        if var status = snapshot.daemonResponse?.status?.vm ?? snapshot.daemonResponse?.vm {
            if let resolved = resolvedVMState(command: command, snapshot: status.state) {
                status.state = resolved
            }
            return status
        }

        if let command {
            return inferredVMStatus(
                state: command,
                socketPath: snapshot.dockerSocketPath,
                message: "Waiting for Conjet VM \(command.rawValue)"
            )
        }

        guard snapshot.dockerReachable else { return nil }
        return inferredVMStatus(
            state: .running,
            socketPath: snapshot.dockerSocketPath,
            message: "Docker socket is reachable; daemon VM status is unavailable"
        )
    }

    private static func vmState(from snapshot: DashboardSnapshot) -> VMRunState? {
        snapshot.daemonResponse?.status?.vm?.state
            ?? snapshot.daemonResponse?.vm?.state
            ?? (snapshot.dockerReachable ? .running : nil)
    }

    private static func inferredVMStatus(
        state: VMRunState,
        socketPath: String,
        message: String
    ) -> VMRuntimeStatus {
        VMRuntimeStatus(
            state: state,
            configured: true,
            manifestPath: "-",
            dockerSocketPath: socketPath.isEmpty ? nil : socketPath,
            message: message
        )
    }

    private static func imageSelectionMatches(_ image: DockerImage, _ selection: String?) -> Bool {
        selection == image.selectionID || selection == image.id
    }

    private static func daemonResponse(from stdout: String) -> DaemonResponse? {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let data = Data(trimmed.utf8)
        let decoder = ConjetJSON.decoder()
        if let response = try? decoder.decode(DaemonResponse.self, from: data) {
            return response
        }
        if let restart = try? decoder.decode(RestartCommandResponse.self, from: data) {
            return restart.started
        }
        if let update = try? decoder.decode(UpdateCommandResponse.self, from: data) {
            return update.started
        }
        return nil
    }

    private struct RestartCommandResponse: Decodable {
        var started: DaemonResponse
    }

    private struct UpdateCommandResponse: Decodable {
        var started: DaemonResponse?
    }
}

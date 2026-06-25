import ConjetAppCore
import ConjetCore
import Foundation
import SwiftUI

enum ManagementSection: String, CaseIterable, Identifiable {
    case overview
    case profiles
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
        case .profiles: "Profiles"
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
        case .profiles: "person.crop.square"
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

private enum DashboardRefreshTrigger {
    case manual
    case automatic
    case pulseEvent
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

struct ProfileConfigDraft: Equatable {
    var profileName: String
    var vmCPUs: Int
    var memoryMiB: Int
    var architecture: String
    var diskGiB: Int
    var diskImagePath: String
    var runtime: String
    var vmBackend: ConjetVMBackend
    var quietStopMinutes: Int
    var enableRosetta: Bool
    var enableHostMounts: Bool
    var enableRemovableHostMounts: Bool
    var socketPath: String
    var conjetCoreRepository: String
    var networkBindPolicy: ConjetNetworkBindPolicy
    var networkProxyEngine: ConjetNetworkProxyEngine
    var networkBridgeEngine: ConjetNetworkBridgeEngine
    var networkLANAllowedCIDRs: String
    var networkLANAllowedPorts: String
    var energyMode: ConjetEnergyMode
    var memoryProfile: ConjetMemoryProfile
    var sshEnabled: Bool
    var sshTransport: String
    var sshAllowTCPFallback: Bool

    init(profileName: String, config: ConjetConfig) {
        self.profileName = profileName
        self.vmCPUs = config.vmCPUs
        self.memoryMiB = config.memoryMiB
        self.architecture = config.architecture
        self.diskGiB = config.diskGiB
        self.diskImagePath = config.diskImagePath ?? ""
        self.runtime = config.runtime
        self.vmBackend = config.vmBackend
        self.quietStopMinutes = config.quietStopMinutes
        self.enableRosetta = config.enableRosetta
        self.enableHostMounts = config.enableHostMounts
        self.enableRemovableHostMounts = config.enableRemovableHostMounts
        self.socketPath = config.socketPath ?? ""
        self.conjetCoreRepository = config.conjetCoreRepository
        self.networkBindPolicy = config.networkBindPolicy
        self.networkProxyEngine = config.networkProxyEngine
        self.networkBridgeEngine = config.networkBridgeEngine
        self.networkLANAllowedCIDRs = config.networkLANAllowedCIDRs.joined(separator: ", ")
        self.networkLANAllowedPorts = config.networkLANAllowedPorts.map(String.init).joined(separator: ", ")
        self.energyMode = config.energyMode
        self.memoryProfile = config.memoryProfile
        self.sshEnabled = config.ssh.enabled
        self.sshTransport = config.ssh.transport
        self.sshAllowTCPFallback = config.ssh.allowTCPFallback
    }

    mutating func clampMemory(to bounds: ConjetProfileMemoryBounds) {
        memoryMiB = bounds.clampedMiB(memoryMiB)
    }

    func makeConfig(memoryBounds: ConjetProfileMemoryBounds? = nil) throws -> ConjetConfig {
        let effectiveMemoryMiB = memoryBounds?.clampedMiB(memoryMiB) ?? memoryMiB
        guard let runtime = ConjetContainerRuntimeKind.parse(trimmed(runtime)) else {
            throw ConjetError.invalidArgument("runtime must be \(ConjetContainerRuntimeKind.allowedValuesDescription)")
        }
        let config = ConjetConfig(
            vmCPUs: vmCPUs,
            memoryMiB: effectiveMemoryMiB,
            architecture: trimmed(architecture),
            diskGiB: diskGiB,
            diskImagePath: optional(trimmed(diskImagePath)),
            runtime: runtime.rawValue,
            vmBackend: vmBackend,
            quietStopMinutes: quietStopMinutes,
            enableRosetta: enableRosetta,
            enableHostMounts: enableHostMounts,
            enableRemovableHostMounts: enableRemovableHostMounts,
            socketPath: optional(trimmed(socketPath)),
            conjetCoreRepository: trimmed(conjetCoreRepository),
            networkBindPolicy: networkBindPolicy,
            networkProxyEngine: networkProxyEngine,
            networkBridgeEngine: networkBridgeEngine,
            networkLANAllowedCIDRs: listValues(from: networkLANAllowedCIDRs),
            networkLANAllowedPorts: try portValues(from: networkLANAllowedPorts),
            energyMode: energyMode,
            memoryProfile: memoryProfile,
            ssh: ConjetSSHPolicy(
                enabled: sshEnabled,
                transport: trimmed(sshTransport),
                allowTCPFallback: sshAllowTCPFallback
            )
        )
        return try ConjetConfig.parseTOML(config.renderTOML())
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func optional(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private func listValues(from value: String) -> [String] {
        value
            .components(separatedBy: CharacterSet(charactersIn: ", \n\t"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func portValues(from value: String) throws -> [Int] {
        try listValues(from: value).map { item in
            guard let port = Int(item), port > 0, port <= 65_535 else {
                throw ConjetError.invalidArgument("network LAN allowed ports must be numbers from 1 to 65535")
            }
            return port
        }
    }
}

@MainActor
final class ConjetAppState: ObservableObject {
    let profileMemoryBounds: ConjetProfileMemoryBounds

    @Published var selectedSection: ManagementSection = .overview {
        didSet {
            if selectedSection != oldValue, managementUpdatesStarted {
                scheduleDeferredRefresh()
            }
        }
    }
    @Published var snapshot: DashboardSnapshot
    @Published var commandLog: [CommandLogEntry] = []
    @Published var isRefreshing = false
    @Published private(set) var interactiveSurfaceVisible = false
    @Published private(set) var pulseConnected = false
    @Published private(set) var pulseHighWatermark: UInt64 = 0
    @Published var activeCommandLabel: String?
    @Published private(set) var commandVMState: VMRunState?
    @Published var selectedContainerID: String?
    @Published var selectedImageID: String?
    @Published var selectedVolumeID: String?
    @Published var selectedProfileName: String?
    @Published var newProfileName = ""
    @Published var profileActionMessage: String?
    @Published var profileActionError: String?
    @Published var profileConfigDraft: ProfileConfigDraft?
    @Published var profileConfigMessage: String?
    @Published var profileConfigError: String?
    @Published var pendingRestartProfileName: String?
    @Published var showProfileRestartPrompt = false
    @Published var dockerEditorSource: String
    @Published var dockerEditorImageTag = "conjet-editor:latest"
    @Published var dockerEditorRunArguments = ""
    @Published var pullImage = "ubuntu:24.04"
    @Published var containerTerminalDebugEnabled = false
    @Published private(set) var containerTerminalError: String?
    @Published var composeDirectory = FileManager.default.currentDirectoryPath
    @Published var composeArguments = "--detach"
    @Published var selectedBindPolicy: ConjetNetworkBindPolicy = .secureLocal
    @Published var selectedBridgeEngine: ConjetNetworkBridgeEngine = .auto

    private let service: ConjetManagementService
    private var refreshTask: Task<Void, Never>?
    private var pulseSubscriptionTask: Task<Void, Never>?
    private var transitionRefreshTask: Task<Void, Never>?
    private var deferredRefreshTask: Task<Void, Never>?
    private var managementUpdatesStarted = false
    private var initialSnapshotLoaded = false
    private var refreshInFlight = false
    private var needsRefreshAfterCurrent = false
    private var needsManualRefreshAfterCurrent = false
    private var isQuitting = false
    private var pendingContainerSelectionName: String?
    private var hiddenStoppedContainerIDs = Set<String>()
    private var lastStatsRefreshAt = Date.distantPast
    private var lastProcessesRefreshAt = Date.distantPast
    private var lastVolumeUsageRefreshAt = Date.distantPast

    private static let transitionRefreshDelayNanoseconds: UInt64 = 250_000_000
    private static let deferredCommandRefreshDelayNanoseconds: UInt64 = 75_000_000
    private static let pulseForegroundReconnectDelayNanoseconds: UInt64 = 5_000_000_000
    private static let pulseBackgroundReconnectDelayNanoseconds: UInt64 = 30_000_000_000
    private static let activityStatsRefreshInterval: TimeInterval = 4
    private static let containerStatsRefreshInterval: TimeInterval = 8
    private static let containerProcessesRefreshInterval: TimeInterval = 15
    private static let volumeUsageRefreshInterval: TimeInterval = 45
    private static let runtimeStartTimeoutSeconds: Double = 300
    private static let runtimeStopTimeoutSeconds: Double = 75
    private static let runtimeRestartTimeoutSeconds: Double = 360
    private static let runtimeUpdateTimeoutSeconds: Double = 900
    private static let dockerLongCommandTimeoutSeconds: Double = 900
    private static let composeCommandTimeoutSeconds: Double = 600
    private static let vmStatusTimeoutSeconds: Double = 30
    private static let vmStartTimeoutSeconds: Double = 300
    private static let vmStopTimeoutSeconds: Double = 90
    private static let vmFetchCoreTimeoutSeconds: Double = 900
    static let defaultDockerfileSource = """
    FROM alpine:3.20
    CMD ["sh", "-c", "echo hello from Conjet && sleep 3600"]
    """

    init(
        service: ConjetManagementService = ConjetManagementService(),
        profileMemoryBounds: ConjetProfileMemoryBounds = ConjetProfileMemoryBounds()
    ) {
        self.service = service
        self.profileMemoryBounds = profileMemoryBounds
        self.snapshot = DashboardSnapshot.empty()
        self.dockerEditorSource = Self.defaultDockerfileSource
    }

    deinit {
        refreshTask?.cancel()
        pulseSubscriptionTask?.cancel()
        transitionRefreshTask?.cancel()
        deferredRefreshTask?.cancel()
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

    var selectedProfileContext: ConjetProfileContext? {
        snapshot.profileContexts.first { $0.name == selectedProfileName }
            ?? snapshot.profileContexts.first { $0.isCurrent }
            ?? snapshot.profileContexts.first
    }

    var currentProfileContext: ConjetProfileContext? {
        snapshot.profileContexts.first { $0.isCurrent }
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
        await refresh(trigger: .manual)
    }

    func refreshAutomaticallyForTesting() async {
        await refresh(trigger: .automatic)
    }

    func applyPulseFrameForTesting(_ frame: ConjetPulseFrame) {
        handlePulseFrame(frame)
    }

    private func refresh(trigger initialTrigger: DashboardRefreshTrigger) async {
        guard !isQuitting else { return }
        if refreshInFlight {
            needsRefreshAfterCurrent = true
            if initialTrigger == .manual {
                needsManualRefreshAfterCurrent = true
            }
            return
        }

        refreshInFlight = true
        var trigger: DashboardRefreshTrigger? = initialTrigger
        repeat {
            guard let currentTrigger = trigger else { break }
            trigger = nil
            needsRefreshAfterCurrent = false
            let showRefreshIndicator = currentTrigger == .manual
            if showRefreshIndicator {
                isRefreshing = true
            }
            let scope = refreshScope(trigger: currentTrigger)
            let latest = await service.loadSnapshot(scope: scope)
            let stable = Self.preservingPreviousResources(current: snapshot, latest: latest)
            let visible = applyingContainerVisibility(to: stable)
            completeCommandTransitionIfNeeded(actual: Self.vmState(from: stable))
            snapshot = visible
            selectedBindPolicy = visible.network?.bindPolicy ?? selectedBindPolicy
            if let bridge = visible.network?.requestedBridgeEngine
                .flatMap(ConjetNetworkBridgeEngine.init(rawValue:)) {
                selectedBridgeEngine = bridge
            }
            if let pendingContainerSelectionName {
                selectedContainerID = visible.containers.first { $0.name == pendingContainerSelectionName }?.id ?? selectedContainerID
                self.pendingContainerSelectionName = nil
            }
            if selectedContainerID == nil {
                selectedContainerID = visible.containers.first?.id
            }
            if selectedImageID == nil || !visible.images.contains(where: { Self.imageSelectionMatches($0, selectedImageID) }) {
                selectedImageID = visible.images.first?.selectionID
            }
            if selectedVolumeID == nil {
                selectedVolumeID = visible.volumes.first?.id
            }
            if selectedProfileName == nil
                || !visible.profileContexts.contains(where: { $0.name == selectedProfileName }) {
                selectedProfileName = visible.profileContexts.first { $0.isCurrent }?.name
                    ?? visible.profileContexts.first?.name
            }
            if showRefreshIndicator {
                isRefreshing = false
            }
            if needsRefreshAfterCurrent {
                trigger = needsManualRefreshAfterCurrent ? .manual : .automatic
                needsManualRefreshAfterCurrent = false
            }
        } while needsRefreshAfterCurrent
        refreshInFlight = false
        isRefreshing = false
    }

    func startAutoRefresh() {
        guard !isQuitting else { return }
        managementUpdatesStarted = true
        startPulseSubscription()
        guard !initialSnapshotLoaded, refreshTask == nil else { return }
        initialSnapshotLoaded = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh(trigger: .automatic)
            if !Task.isCancelled {
                self.refreshTask = nil
            }
        }
    }

    func setInteractiveSurfaceVisible(_ isVisible: Bool) {
        guard interactiveSurfaceVisible != isVisible else { return }
        interactiveSurfaceVisible = isVisible
        if isVisible {
            scheduleDeferredRefresh(trigger: .automatic)
        }
    }

    func createProfile(switchToNew: Bool) async {
        guard !isQuitting else { return }
        let profileName = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profileName.isEmpty else {
            profileActionMessage = nil
            profileActionError = "Enter a profile name."
            return
        }

        let label = switchToNew ? "Create & Use Profile" : "Create Profile"
        let startedAt = Date()
        activeCommandLabel = label
        profileActionMessage = nil
        profileActionError = nil
        do {
            let status = try service.createProfile(named: profileName)
            var stdout = "created profile \(status.profile) at \(status.home)"
            if switchToNew {
                let activation = try service.switchProfile(named: status.profile)
                applyProfileSwitch(activation)
                stdout += "\nusing profile \(activation.profile)"
                profileActionMessage = "Using profile \(activation.profile). Other profile VMs were left running."
            } else {
                selectedProfileName = status.profile
                profileActionMessage = "Created profile \(status.profile)."
            }
            newProfileName = ""
            recordCommand(CommandLogEntry(
                label: label,
                commandLine: switchToNew ? "conjet profile create \(status.profile) && conjet profile use \(status.profile)" : "conjet profile create \(status.profile)",
                startedAt: startedAt,
                finishedAt: Date(),
                exitCode: 0,
                stdout: stdout,
                stderr: ""
            ))
            activeCommandLabel = nil
            await refresh()
        } catch {
            let message = String(describing: error)
            profileActionError = message
            recordCommand(CommandLogEntry(
                label: label,
                commandLine: switchToNew ? "conjet profile create \(profileName) && conjet profile use \(profileName)" : "conjet profile create \(profileName)",
                startedAt: startedAt,
                finishedAt: Date(),
                exitCode: 1,
                stdout: "",
                stderr: message
            ))
            activeCommandLabel = nil
        }
    }

    func switchProfile(_ profile: ConjetProfileContext) async {
        await switchProfile(named: profile.name)
    }

    func switchProfile(named profileName: String) async {
        guard !isQuitting else { return }
        if currentProfileContext?.name == profileName {
            selectedProfileName = profileName
            profileActionMessage = "Profile \(profileName) is already current."
            profileActionError = nil
            return
        }

        let startedAt = Date()
        activeCommandLabel = "Use Profile"
        profileActionMessage = nil
        profileActionError = nil
        do {
            let activation = try service.switchProfile(named: profileName)
            applyProfileSwitch(activation)
            recordCommand(CommandLogEntry(
                label: "Use Profile",
                commandLine: "conjet profile use \(activation.profile)",
                startedAt: startedAt,
                finishedAt: Date(),
                exitCode: 0,
                stdout: "using profile \(activation.profile)\nprevious profile \(activation.previousProfile)",
                stderr: ""
            ))
            profileActionMessage = "Using profile \(activation.profile). Other profile VMs were left running."
            activeCommandLabel = nil
            await refresh()
        } catch {
            let message = String(describing: error)
            profileActionError = message
            recordCommand(CommandLogEntry(
                label: "Use Profile",
                commandLine: "conjet profile use \(profileName)",
                startedAt: startedAt,
                finishedAt: Date(),
                exitCode: 1,
                stdout: "",
                stderr: message
            ))
            activeCommandLabel = nil
        }
    }

    func loadProfileConfig(_ profile: ConjetProfileContext, force: Bool = false) {
        guard !isQuitting else { return }
        guard force || profileConfigDraft?.profileName != profile.name else { return }
        profileConfigMessage = nil
        profileConfigError = nil
        do {
            let result = try service.loadProfileConfig(named: profile.name)
            var draft = ProfileConfigDraft(profileName: result.profile, config: result.config)
            draft.clampMemory(to: profileMemoryBounds)
            profileConfigDraft = draft
        } catch {
            profileConfigDraft = nil
            profileConfigError = String(describing: error)
        }
    }

    func saveProfileConfig() async {
        guard !isQuitting else { return }
        guard let draft = profileConfigDraft else {
            profileConfigMessage = nil
            profileConfigError = "Profile settings are not loaded."
            return
        }

        let label = "Save Profile Settings"
        let startedAt = Date()
        activeCommandLabel = label
        profileConfigMessage = nil
        profileConfigError = nil
        do {
            var clampedDraft = draft
            clampedDraft.clampMemory(to: profileMemoryBounds)
            profileConfigDraft = clampedDraft
            let config = try clampedDraft.makeConfig(memoryBounds: profileMemoryBounds)
            let result = try service.saveProfileConfig(named: draft.profileName, config: config)
            profileConfigDraft = ProfileConfigDraft(profileName: result.profile, config: result.config)
            selectedProfileName = result.profile
            pendingRestartProfileName = result.profile
            showProfileRestartPrompt = true
            profileConfigMessage = "Saved profile \(result.profile)."
            recordCommand(CommandLogEntry(
                label: label,
                commandLine: "write \(result.configPath)",
                startedAt: startedAt,
                finishedAt: Date(),
                exitCode: 0,
                stdout: "saved profile \(result.profile) settings at \(result.configPath)",
                stderr: ""
            ))
            activeCommandLabel = nil
            await refresh()
        } catch {
            let message = String(describing: error)
            profileConfigError = message
            recordCommand(CommandLogEntry(
                label: label,
                commandLine: "write profile \(draft.profileName) config",
                startedAt: startedAt,
                finishedAt: Date(),
                exitCode: 1,
                stdout: "",
                stderr: message
            ))
            activeCommandLabel = nil
        }
    }

    func restartPendingProfileNow() async {
        guard let profileName = pendingRestartProfileName, !profileName.isEmpty else {
            showProfileRestartPrompt = false
            return
        }
        showProfileRestartPrompt = false
        if currentProfileContext?.name != profileName {
            await switchProfile(named: profileName)
        }
        guard currentProfileContext?.name == profileName else {
            profileConfigError = "Could not switch to profile \(profileName) for restart."
            return
        }

        await runAndRefresh(label: "Restart \(profileName)", vmTransition: .starting) {
            await service.runConjetCompatibility(
                ["restart", "--json"],
                label: "Restart \(profileName)",
                timeoutSeconds: Self.runtimeRestartTimeoutSeconds
            )
        }
        pendingRestartProfileName = nil
        profileConfigMessage = "Restarted profile \(profileName)."
    }

    func restartPendingProfileLater() {
        guard let profileName = pendingRestartProfileName else {
            showProfileRestartPrompt = false
            return
        }
        showProfileRestartPrompt = false
        pendingRestartProfileName = nil
        profileConfigMessage = "Saved profile \(profileName)."
    }

    private var selectedSectionNeedsContinuousRefresh: Bool {
        switch selectedSection {
        case .activity, .containers, .processes:
            return true
        case .overview, .profiles, .compose, .machines, .images, .volumes, .network, .commands:
            return false
        }
    }

    func startRuntime() async {
        await runAndRefresh(label: "Start Conjet", vmTransition: .starting) {
            await service.runConjetCompatibility(
                ["start", "--json"],
                label: "Start Conjet",
                timeoutSeconds: Self.runtimeStartTimeoutSeconds
            )
        }
    }

    func stopRuntime() async {
        await runAndRefresh(label: "Stop Conjet", vmTransition: .stopping) {
            await service.stopRuntime(
                label: "Stop Conjet",
                timeoutSeconds: Self.runtimeStopTimeoutSeconds
            )
        }
    }

    func prepareForQuit() {
        isQuitting = true
        stopAutoRefresh()
    }

    func stopForQuit() async {
        prepareForQuit()
        activeCommandLabel = "Quit Conjet"
        setCommandVMState(.stopping)
        let entry = await service.stopRuntimeForQuit(
            daemonTimeoutSeconds: 10,
            label: "Quit Conjet"
        )
        commandLog.insert(entry, at: 0)
        commandLog = Array(commandLog.prefix(80))
        activeCommandLabel = nil
        setCommandVMState(nil)
    }

    func restartRuntime() async {
        await runAndRefresh(label: "Restart Conjet", vmTransition: .starting) {
            await service.runConjetCompatibility(
                ["restart", "--json"],
                label: "Restart Conjet",
                timeoutSeconds: Self.runtimeRestartTimeoutSeconds
            )
        }
    }

    func updateRuntime() async {
        await runAndRefresh(label: "Update Conjet Core", vmTransition: .starting) {
            await service.runConjetCompatibility(
                ["update", "--restart", "--json"],
                label: "Update Conjet Core",
                timeoutSeconds: Self.runtimeUpdateTimeoutSeconds
            )
        }
    }

    func runDockerEditor() async {
        let source = dockerEditorSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }

        let imageTag = dockerEditorImageReference()
        let runID = Self.shortRunIdentifier()
        let containerName = "conjet-editor-\(runID)"
        let buildDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conjet-docker-editor-\(UUID().uuidString)", isDirectory: true)
        let dockerfileURL = buildDirectory.appendingPathComponent("Dockerfile")

        activeCommandLabel = "Build Dockerfile"
        do {
            try FileManager.default.createDirectory(at: buildDirectory, withIntermediateDirectories: true)
            try source.write(to: dockerfileURL, atomically: true, encoding: .utf8)
        } catch {
            recordCommand(CommandLogEntry(
                label: "Build Dockerfile",
                commandLine: "write \(dockerfileURL.path)",
                startedAt: Date(),
                finishedAt: Date(),
                exitCode: 1,
                stdout: "",
                stderr: String(describing: error)
            ))
            activeCommandLabel = nil
            return
        }
        defer { try? FileManager.default.removeItem(at: buildDirectory) }

        let buildEntry = await service.runDocker(
            ["build", "--label", "io.conjet.source=docker-editor", "--tag", imageTag, "."],
            label: "Build Dockerfile",
            workingDirectory: buildDirectory,
            timeoutSeconds: Self.dockerLongCommandTimeoutSeconds
        )
        recordCommand(buildEntry)
        guard buildEntry.succeeded else {
            activeCommandLabel = nil
            await refresh()
            return
        }

        activeCommandLabel = "Run \(containerName)"
        let runEntry = await service.runDocker(
            [
                "run",
                "--detach",
                "--rm",
                "--name", containerName,
                "--label", "io.conjet.source=docker-editor"
            ] + splitArguments(dockerEditorRunArguments) + [imageTag],
            label: "Run \(containerName)",
            timeoutSeconds: Self.dockerLongCommandTimeoutSeconds
        )
        recordCommand(runEntry)
        activeCommandLabel = nil
        if runEntry.succeeded {
            applyOptimisticRunContainer(
                id: Self.firstOutputLine(from: runEntry.stdout) ?? containerName,
                name: containerName,
                image: imageTag
            )
            pendingContainerSelectionName = containerName
        }
        scheduleDeferredRefresh()
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
        } optimisticUpdate: { [action] _ in
            self.applyOptimisticContainerAction(action, containerIDs: [container.id])
        }
    }

    func prepareContainerTerminal(container: DockerContainer) -> DockerTerminalCommand? {
        guard !isQuitting else { return nil }
        let startedAt = Date()
        do {
            let command = try service.dockerExecTerminalCommand(
                container: container,
                debugEnabled: containerTerminalDebugEnabled
            )
            containerTerminalError = nil
            recordCommand(CommandLogEntry(
                label: command.title,
                commandLine: command.commandLine,
                startedAt: startedAt,
                finishedAt: Date(),
                exitCode: 0,
                stdout: "started embedded terminal for \(container.name) using \(command.shellPath)",
                stderr: ""
            ))
            return command
        } catch {
            let message = String(describing: error)
            containerTerminalError = message
            recordCommand(CommandLogEntry(
                label: "Terminal \(container.name)",
                commandLine: "docker exec -it \(container.id) /bin/sh",
                startedAt: startedAt,
                finishedAt: Date(),
                exitCode: 1,
                stdout: "",
                stderr: message
            ))
            return nil
        }
    }

    func containerGroupAction(_ action: String, group: ContainerGroup) async {
        let label = "\(action.capitalized) \(group.title)"
        switch action {
        case "up":
            guard let compose = composeContext(for: group) else { return }
            await runAndRefresh(label: "Compose Up \(compose.project)") {
                await service.runCompose(
                    compose.fileArguments + ["-p", compose.project, "up", "--detach"],
                    workingDirectory: compose.workingDirectory,
                    label: "Compose Up \(compose.project)"
                )
            } optimisticUpdate: { _ in
                self.applyOptimisticContainerAction("start", containerIDs: Set(group.startableContainers.map(\.id)))
            }
        case "down":
            guard let compose = composeContext(for: group) else { return }
            await runAndRefresh(label: "Compose Down \(compose.project)") {
                await service.runCompose(
                    compose.fileArguments + ["-p", compose.project, "down"],
                    workingDirectory: compose.workingDirectory,
                    label: "Compose Down \(compose.project)"
                )
            } optimisticUpdate: { _ in
                self.applyOptimisticContainerAction("remove", containerIDs: Set(group.containers.map(\.id)))
            }
        case "start":
            let ids = group.startableContainers.map(\.id)
            guard !ids.isEmpty else { return }
            await runAndRefresh(label: label) {
                await service.runDocker(["start"] + ids, label: label, timeoutSeconds: 60)
            } optimisticUpdate: { _ in
                self.applyOptimisticContainerAction("start", containerIDs: Set(ids))
            }
        case "stop":
            if let compose = composeContext(for: group) {
                await runAndRefresh(label: "Compose Stop \(compose.project)") {
                    await service.runCompose(
                        compose.fileArguments + ["-p", compose.project, "stop"],
                        workingDirectory: compose.workingDirectory,
                        label: "Compose Stop \(compose.project)"
                    )
                } optimisticUpdate: { _ in
                    self.applyOptimisticContainerAction("stop", containerIDs: Set(group.containers.filter(\.isRunning).map(\.id)))
                }
                return
            }
            let ids = group.containers.filter(\.isRunning).map(\.id)
            guard !ids.isEmpty else { return }
            await runAndRefresh(label: label) {
                await service.runDocker(["stop"] + ids, label: label, timeoutSeconds: 60)
            } optimisticUpdate: { _ in
                self.applyOptimisticContainerAction("stop", containerIDs: Set(ids))
            }
        case "restart":
            if let compose = composeContext(for: group) {
                await runAndRefresh(label: "Compose Restart \(compose.project)") {
                    await service.runCompose(
                        compose.fileArguments + ["-p", compose.project, "restart"],
                        workingDirectory: compose.workingDirectory,
                        label: "Compose Restart \(compose.project)"
                    )
                } optimisticUpdate: { _ in
                    self.applyOptimisticContainerAction("restart", containerIDs: Set(group.containers.map(\.id)))
                }
                return
            }
            let ids = group.containers.map(\.id)
            guard !ids.isEmpty else { return }
            await runAndRefresh(label: label) {
                await service.runDocker(["restart"] + ids, label: label, timeoutSeconds: 120)
            } optimisticUpdate: { _ in
                self.applyOptimisticContainerAction("restart", containerIDs: Set(ids))
            }
        default:
            return
        }
    }

    private func composeContext(for group: ContainerGroup) -> (
        project: String,
        workingDirectory: URL,
        fileArguments: [String]
    )? {
        guard let project = group.composeProject,
              let workingDirectory = group.composeWorkingDirectory else {
            return nil
        }
        return (
            project: project,
            workingDirectory: URL(fileURLWithPath: workingDirectory, isDirectory: true),
            fileArguments: group.composeConfigFiles.flatMap { ["-f", $0] }
        )
    }

    func pullImageAction() async {
        let image = pullImage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !image.isEmpty else { return }
        await runAndRefresh(label: "Pull \(image)") {
            await service.runDocker(
                ["pull", image],
                label: "Pull \(image)",
                timeoutSeconds: Self.dockerLongCommandTimeoutSeconds
            )
        }
    }

    func removeImage(_ image: DockerImage) async {
        await runAndRefresh(label: "Remove \(image.reference)") {
            await service.runDocker(["rmi", image.reference], label: "Remove \(image.reference)", timeoutSeconds: 120)
        } optimisticUpdate: { _ in
            self.removeImageFromSnapshot(image)
        }
    }

    func removeVolume(_ volume: DockerVolume) async {
        await runAndRefresh(label: "Remove volume \(volume.name)") {
            await service.runDocker(["volume", "rm", volume.name], label: "Remove volume \(volume.name)", timeoutSeconds: 60)
        } optimisticUpdate: { _ in
            self.removeVolumeFromSnapshot(volume)
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
            await service.runCompose(
                args,
                workingDirectory: directory,
                label: "Compose \(action)",
                timeoutSeconds: Self.composeCommandTimeoutSeconds
            )
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
            await service.runConjetCompatibility(args, label: "VM \(action)", timeoutSeconds: Self.vmTimeout(for: action))
        }
    }

    func repairNetwork() async {
        await runAndRefresh(label: "Repair network") {
            await service.runConjetCompatibility(["network", "repair"], label: "Repair network", timeoutSeconds: 60)
        }
    }

    func bridgeTest() async {
        await runAndRefresh(label: "Network bridge test") {
            await service.runConjetCompatibility(["network", "bridge-test"], label: "Network bridge test", timeoutSeconds: 60)
        }
    }

    func applyNetworkPolicy() async {
        await runAndRefresh(label: "Set network policy") {
            await service.runConjetCompatibility(
                ["network", "policy", "set", selectedBindPolicy.rawValue],
                label: "Set network policy",
                timeoutSeconds: 30
            )
        }
        guard selectedBridgeEngine != .auto else { return }
        await runAndRefresh(label: "Switch bridge engine") {
            await service.runConjetCompatibility(
                ["network", "bridge-switch", selectedBridgeEngine.rawValue, "--restart"],
                label: "Switch bridge engine",
                timeoutSeconds: Self.runtimeRestartTimeoutSeconds
            )
        }
    }

    func clearCommandLog() {
        commandLog.removeAll()
    }

    private func runAndRefresh(
        label: String,
        vmTransition: VMRunState? = nil,
        operation: () async -> CommandLogEntry,
        optimisticUpdate: ((CommandLogEntry) -> Void)? = nil
    ) async {
        guard !isQuitting else { return }
        activeCommandLabel = label
        if let vmTransition {
            setCommandVMState(vmTransition)
        }
        let entry = await operation()
        recordCommand(entry)
        if let response = Self.daemonResponse(from: entry.stdout) {
            applyDaemonResponse(response)
        }
        if entry.succeeded {
            optimisticUpdate?(entry)
        }
        activeCommandLabel = nil
        if vmTransition != nil {
            setCommandVMState(nil)
        }
        scheduleDeferredRefresh()
    }

    private func recordCommand(_ entry: CommandLogEntry) {
        commandLog.insert(entry, at: 0)
        commandLog = Array(commandLog.prefix(80))
    }

    private func applyProfileSwitch(_ activation: ConjetProfileActivationResult) {
        selectedProfileName = activation.profile
        selectedContainerID = nil
        selectedImageID = nil
        selectedVolumeID = nil
        pendingContainerSelectionName = nil
        hiddenStoppedContainerIDs.removeAll()
        setCommandVMState(nil)
    }

    private func splitArguments(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private func dockerEditorImageReference() -> String {
        let value = dockerEditorImageTag.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "conjet-editor:latest" : value
    }

    private static func shortRunIdentifier() -> String {
        String(UUID().uuidString.lowercased().prefix(8))
    }

    private static func firstOutputLine(from output: String) -> String? {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private var snapshotVMState: VMRunState? {
        Self.vmState(from: snapshot)
    }

    private func refreshScope(
        trigger: DashboardRefreshTrigger,
        now: Date = Date()
    ) -> DashboardSnapshotRefreshScope {
        guard trigger == .manual || interactiveSurfaceVisible else {
            return .statusOnly
        }
        if trigger == .automatic, pulseConnected, !selectedSectionNeedsContinuousRefresh {
            return .statusOnly
        }

        switch selectedSection {
        case .activity:
            var scope = DashboardSnapshotRefreshScope.containers
            if now.timeIntervalSince(lastStatsRefreshAt) >= Self.activityStatsRefreshInterval {
                scope.includeStats = true
                lastStatsRefreshAt = now
            }
            return scope
        case .processes:
            var scope = DashboardSnapshotRefreshScope.containers
            if now.timeIntervalSince(lastProcessesRefreshAt) >= Self.containerProcessesRefreshInterval {
                scope.includeProcesses = true
                lastProcessesRefreshAt = now
            }
            return scope
        case .containers:
            var scope = DashboardSnapshotRefreshScope.containers
            if now.timeIntervalSince(lastStatsRefreshAt) >= Self.containerStatsRefreshInterval {
                scope.includeStats = true
                lastStatsRefreshAt = now
            }
            if now.timeIntervalSince(lastProcessesRefreshAt) >= Self.containerProcessesRefreshInterval {
                scope.includeProcesses = true
                lastProcessesRefreshAt = now
            }
            return scope
        case .volumes:
            var includeUsage = false
            if trigger == .manual || now.timeIntervalSince(lastVolumeUsageRefreshAt) >= Self.volumeUsageRefreshInterval {
                includeUsage = true
                lastVolumeUsageRefreshAt = now
            }
            return .volumes(includeUsage: includeUsage)
        case .images:
            return .images
        case .compose:
            return .containers
        case .overview:
            return .inventory
        case .network:
            return .networks
        case .profiles, .machines, .commands:
            return .statusOnly
        }
    }

    private func applyDaemonResponse(_ response: DaemonResponse) {
        var latest = snapshot
        latest.daemonResponse = response
        latest.network = response.status?.network ?? latest.network
        completeCommandTransitionIfNeeded(actual: Self.vmState(from: latest))
        snapshot = latest
    }

    private func scheduleDeferredRefresh(
        trigger: DashboardRefreshTrigger = .manual
    ) {
        guard !isQuitting else { return }
        deferredRefreshTask?.cancel()
        deferredRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.deferredCommandRefreshDelayNanoseconds)
            guard !Task.isCancelled, let self else { return }
            await self.refresh(trigger: trigger)
            if !Task.isCancelled {
                self.deferredRefreshTask = nil
            }
        }
    }

    private func startPulseSubscription() {
        guard !isQuitting, pulseSubscriptionTask == nil else { return }
        let service = service
        pulseSubscriptionTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let sinceSequence = await MainActor.run { self.pulseHighWatermark }
                do {
                    try service.streamPulse(sinceSequence: sinceSequence) { frame in
                        if Task.isCancelled {
                            return false
                        }
                        Task { @MainActor [weak self] in
                            self?.handlePulseFrame(frame)
                        }
                        return true
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    let delay = await MainActor.run { () -> UInt64 in
                        self.pulseConnected = false
                        return self.pulseReconnectDelayNanoseconds
                    }
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }
    }

    private var pulseReconnectDelayNanoseconds: UInt64 {
        interactiveSurfaceVisible
            ? Self.pulseForegroundReconnectDelayNanoseconds
            : Self.pulseBackgroundReconnectDelayNanoseconds
    }

    private func handlePulseFrame(_ frame: ConjetPulseFrame) {
        guard !isQuitting else { return }
        pulseConnected = true
        pulseHighWatermark = max(pulseHighWatermark, frame.state.highWatermark)

        guard frame.kind != .heartbeat else { return }
        guard frame.overflowed || frame.events.contains(where: Self.pulseEventShouldRefresh) else { return }
        scheduleDeferredRefresh(trigger: .pulseEvent)
    }

    private static func pulseEventShouldRefresh(_ event: ConjetPulseEvent) -> Bool {
        switch event.type {
        case .daemonStarted,
             .daemonStopping,
             .vmStarting,
             .vmStarted,
             .vmStopping,
             .vmStopped,
             .vmErrored,
             .containerCreated,
             .containerStarted,
             .containerStopped,
             .containerRemoved,
             .imageChanged,
             .volumeChanged,
             .networkChanged,
             .clockRepaired,
             .cachePruned,
             .memoryReclaimed,
             .dockerRunFinished,
             .commandFinished:
            true
        }
    }

    private func applyOptimisticContainerAction(_ action: String, containerIDs: Set<String>) {
        guard !containerIDs.isEmpty else { return }
        switch action {
        case "remove", "rm", "down":
            hiddenStoppedContainerIDs.subtract(containerIDs)
            snapshot.containers.removeAll { containerIDs.contains($0.id) }
            if let selectedContainerID, containerIDs.contains(selectedContainerID) {
                self.selectedContainerID = snapshot.containers.first?.id
            }
        case "stop":
            hiddenStoppedContainerIDs.formUnion(containerIDs)
            snapshot.containers.removeAll { containerIDs.contains($0.id) }
            if let selectedContainerID, containerIDs.contains(selectedContainerID) {
                self.selectedContainerID = snapshot.containers.first?.id
            }
        default:
            hiddenStoppedContainerIDs.subtract(containerIDs)
            snapshot.containers = snapshot.containers.map { container in
                guard containerIDs.contains(container.id) else { return container }
                var copy = container
                switch action {
                case "start", "restart", "up":
                    copy.state = "running"
                    copy.status = "Up just now"
                case "stop":
                    copy.state = "exited"
                    copy.status = "Exited"
                default:
                    break
                }
                return copy
            }
        }
        snapshot.stats.removeAll { containerIDs.contains($0.container) }
        snapshot.containerProcesses.removeAll { containerIDs.contains($0.containerID) }
        rebuildContainerActivity()
    }

    private func applyOptimisticRunContainer(id: String, name: String, image: String) {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let containerID = trimmedID.isEmpty ? name : trimmedID
        hiddenStoppedContainerIDs.remove(containerID)
        hiddenStoppedContainerIDs = hiddenStoppedContainerIDs.filter { hiddenID in
            !snapshot.containers.contains { $0.id == hiddenID && $0.name == name }
        }

        let container = DockerContainer(
            id: containerID,
            name: name,
            image: image,
            state: "running",
            status: "Up just now",
            labels: "io.conjet.source=docker-editor"
        )

        snapshot.containers.removeAll { $0.id == containerID || $0.name == name }
        snapshot.containers.insert(container, at: 0)
        selectedContainerID = containerID
        rebuildContainerActivity()
    }

    private func applyingContainerVisibility(to input: DashboardSnapshot) -> DashboardSnapshot {
        var output = input
        let presentIDs = Set(output.containers.map(\.id))
        let runningIDs = Set(output.containers.filter(\.isRunning).map(\.id))
        hiddenStoppedContainerIDs = hiddenStoppedContainerIDs.intersection(presentIDs)
        hiddenStoppedContainerIDs.subtract(runningIDs)

        guard !hiddenStoppedContainerIDs.isEmpty else { return output }
        output.containers.removeAll {
            hiddenStoppedContainerIDs.contains($0.id) && !$0.isRunning
        }
        output.stats.removeAll {
            hiddenStoppedContainerIDs.contains($0.container)
        }
        output.containerProcesses.removeAll {
            hiddenStoppedContainerIDs.contains($0.containerID)
        }
        output.containerActivity = ContainerActivitySnapshot(
            containers: output.containers,
            stats: output.stats,
            processes: output.containerProcesses
        )
        return output
    }

    private func rebuildContainerActivity() {
        snapshot.containerActivity = ContainerActivitySnapshot(
            containers: snapshot.containers,
            stats: snapshot.stats,
            processes: snapshot.containerProcesses
        )
    }

    private func removeImageFromSnapshot(_ image: DockerImage) {
        snapshot.images.removeAll { Self.imageSelectionMatches($0, image.selectionID) || $0.id == image.id }
        if selectedImageID == image.selectionID || selectedImageID == image.id {
            selectedImageID = snapshot.images.first?.selectionID
        }
    }

    private func removeVolumeFromSnapshot(_ volume: DockerVolume) {
        snapshot.volumes.removeAll { $0.id == volume.id }
        if selectedVolumeID == volume.id {
            selectedVolumeID = snapshot.volumes.first?.id
        }
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
        guard !isQuitting else { return }
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

    static func preservingPreviousResources(
        current: DashboardSnapshot,
        latest: DashboardSnapshot
    ) -> DashboardSnapshot {
        if didSwitchProfile(from: current, to: latest) {
            return latest
        }

        var merged = latest
        let refresh = latest.refreshStatus

        if !refresh.containersSucceeded {
            merged.containers = current.containers
        }
        if !refresh.imagesSucceeded {
            merged.images = current.images
        }
        if !refresh.volumesSucceeded {
            merged.volumes = current.volumes
        } else {
            merged.volumes = preservingPreviousVolumeSizes(current: current.volumes, latest: latest.volumes)
        }
        if !refresh.dockerNetworksSucceeded {
            merged.dockerNetworks = current.dockerNetworks
        }
        if !refresh.statsSucceeded {
            merged.stats = current.stats
        }
        if !refresh.processesSucceeded {
            merged.containerProcesses = current.containerProcesses
        }
        if !refresh.networkSucceeded {
            merged.network = current.network
        }

        pruneActivityRowsWithoutContainers(in: &merged)
        merged.containerActivity = ContainerActivitySnapshot(
            containers: merged.containers,
            stats: merged.stats,
            processes: merged.containerProcesses
        )
        return merged
    }

    private static func preservingPreviousVolumeSizes(
        current: [DockerVolume],
        latest: [DockerVolume]
    ) -> [DockerVolume] {
        let previousSizes: [(String, String)] = current.compactMap { volume in
            let size = volume.size.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !size.isEmpty, size != "N/A" else { return nil }
            return (volume.name, size)
        }
        let previousSizeByName = Dictionary(uniqueKeysWithValues: previousSizes)

        return latest.map { volume in
            let size = volume.size.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (size.isEmpty || size == "N/A"), let previousSize = previousSizeByName[volume.name] else {
                return volume
            }
            var copy = volume
            copy.size = previousSize
            return copy
        }
    }

    private static func pruneActivityRowsWithoutContainers(in snapshot: inout DashboardSnapshot) {
        guard !snapshot.containers.isEmpty else {
            snapshot.stats.removeAll()
            snapshot.containerProcesses.removeAll()
            return
        }
        snapshot.stats.removeAll { stat in
            !snapshot.containers.contains { container in
                container.id == stat.container
                    || container.id.hasPrefix(stat.container)
                    || stat.container.hasPrefix(container.id)
                    || container.name == stat.name
            }
        }
        snapshot.containerProcesses.removeAll { process in
            !snapshot.containers.contains { container in
                container.id == process.containerID
                    || container.id.hasPrefix(process.containerID)
                    || process.containerID.hasPrefix(container.id)
                    || container.name == process.containerName
            }
        }
    }

    private static func didSwitchProfile(from current: DashboardSnapshot, to latest: DashboardSnapshot) -> Bool {
        let currentProfile = current.profileContexts.first { $0.isCurrent }?.name
        let latestProfile = latest.profileContexts.first { $0.isCurrent }?.name
        if let currentProfile, let latestProfile, currentProfile != latestProfile {
            return true
        }
        guard !current.dockerSocketPath.isEmpty, !latest.dockerSocketPath.isEmpty else {
            return false
        }
        return current.dockerSocketPath != latest.dockerSocketPath
    }

    private func stopAutoRefresh() {
        refreshTask?.cancel()
        pulseSubscriptionTask?.cancel()
        transitionRefreshTask?.cancel()
        deferredRefreshTask?.cancel()
        refreshTask = nil
        pulseSubscriptionTask = nil
        transitionRefreshTask = nil
        deferredRefreshTask = nil
        managementUpdatesStarted = false
        initialSnapshotLoaded = false
        pulseConnected = false
        needsRefreshAfterCurrent = false
    }

    private static func vmTimeout(for action: String) -> Double {
        switch action {
        case "start":
            vmStartTimeoutSeconds
        case "stop":
            vmStopTimeoutSeconds
        case "status", "logs":
            vmStatusTimeoutSeconds
        case "fetchCore":
            vmFetchCoreTimeoutSeconds
        default:
            runtimeStartTimeoutSeconds
        }
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

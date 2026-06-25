import ConjetCore
import ConjetManagement
import Foundation

public struct DashboardSnapshotRefreshScope: Equatable, Sendable {
    public var includeContainers: Bool
    public var includeImages: Bool
    public var includeVolumes: Bool
    public var includeNetworks: Bool
    public var includeVolumeUsage: Bool
    public var includeStats: Bool
    public var includeProcesses: Bool

    public var includeDockerInventory: Bool {
        includeContainers || includeImages || includeVolumes || includeNetworks || includeStats || includeProcesses
    }

    public init(
        includeDockerInventory: Bool = true,
        includeContainers: Bool? = nil,
        includeImages: Bool? = nil,
        includeVolumes: Bool? = nil,
        includeNetworks: Bool? = nil,
        includeVolumeUsage: Bool = false,
        includeStats: Bool = false,
        includeProcesses: Bool = false
    ) {
        self.includeContainers = includeContainers ?? includeDockerInventory
        self.includeImages = includeImages ?? includeDockerInventory
        self.includeVolumes = includeVolumes ?? includeDockerInventory
        self.includeNetworks = includeNetworks ?? includeDockerInventory
        self.includeVolumeUsage = includeVolumeUsage
        self.includeStats = includeStats
        self.includeProcesses = includeProcesses
    }

    public static let statusOnly = DashboardSnapshotRefreshScope(includeDockerInventory: false)
    public static let inventory = DashboardSnapshotRefreshScope()
    public static let containers = DashboardSnapshotRefreshScope(
        includeDockerInventory: false,
        includeContainers: true
    )
    public static let images = DashboardSnapshotRefreshScope(
        includeDockerInventory: false,
        includeImages: true
    )
    public static func volumes(includeUsage: Bool = false) -> DashboardSnapshotRefreshScope {
        DashboardSnapshotRefreshScope(
            includeDockerInventory: false,
            includeVolumes: true,
            includeVolumeUsage: includeUsage
        )
    }
    public static let networks = DashboardSnapshotRefreshScope(
        includeDockerInventory: false,
        includeNetworks: true
    )
    public static let activity = DashboardSnapshotRefreshScope(
        includeDockerInventory: false,
        includeContainers: true,
        includeStats: true
    )
    public static let processes = DashboardSnapshotRefreshScope(
        includeDockerInventory: false,
        includeContainers: true,
        includeProcesses: true
    )
    public static let detailed = DashboardSnapshotRefreshScope(
        includeDockerInventory: false,
        includeContainers: true,
        includeStats: true,
        includeProcesses: true
    )
}

public struct DockerTerminalCommand: Equatable, Sendable {
    public var title: String
    public var executable: String
    public var arguments: [String]
    public var environment: [String]
    public var commandLine: String
    public var containerID: String
    public var containerName: String
    public var shellPath: String
    public var debugEnabled: Bool
    public var dockerSocketPath: String

    public init(
        title: String,
        executable: String,
        arguments: [String],
        environment: [String],
        commandLine: String,
        containerID: String,
        containerName: String,
        shellPath: String,
        debugEnabled: Bool = false,
        dockerSocketPath: String
    ) {
        self.title = title
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.commandLine = commandLine
        self.containerID = containerID
        self.containerName = containerName
        self.shellPath = shellPath
        self.debugEnabled = debugEnabled
        self.dockerSocketPath = dockerSocketPath
    }
}

public struct ConjetManagementService: Sendable {
    private let runtime: ConjetRuntimeManagementService

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        conjetTool: ResolvedTool? = nil,
        conjetCoreTool: ResolvedTool? = nil,
        dockerTool: ResolvedTool? = nil,
        includeLaunchdEnvironment: Bool = true,
        persistedRuntimeEnvironmentURL: URL? = nil,
        executor: any CommandExecuting = LocalCommandExecutor()
    ) {
        self.runtime = ConjetRuntimeManagementService(
            environment: environment,
            conjetTool: conjetTool,
            conjetCoreTool: conjetCoreTool,
            dockerTool: dockerTool,
            includeLaunchdEnvironment: includeLaunchdEnvironment,
            persistedRuntimeEnvironmentURL: persistedRuntimeEnvironmentURL,
            executor: executor
        )
    }

    public func loadSnapshot(scope: DashboardSnapshotRefreshScope = .inventory) async -> DashboardSnapshot {
        let context = runtime.runtimeContext()
        let socketPath = context.paths.dockerSocket.path
        let socketAvailable = FileManager.default.fileExists(atPath: socketPath)

        async let daemon = daemonStatus(context: context)
        async let profiles = profileList(context: context)
        async let containers = scope.includeContainers
            ? dockerContainers(socketAvailable: socketAvailable, context: context)
            : ProbeResult(value: [], warnings: [], succeeded: false)
        async let images = scope.includeImages
            ? dockerImages(socketAvailable: socketAvailable, context: context)
            : ProbeResult(value: [], warnings: [], succeeded: false)
        async let volumes = scope.includeVolumes
            ? dockerVolumes(
                socketAvailable: socketAvailable,
                includeUsage: scope.includeVolumeUsage,
                context: context
            )
            : ProbeResult(value: [], warnings: [], succeeded: false)
        async let networks = scope.includeNetworks
            ? dockerNetworks(socketAvailable: socketAvailable, context: context)
            : ProbeResult(value: [], warnings: [], succeeded: false)
        async let stats: ProbeResult<[DockerStats]> = scope.includeStats
            ? dockerStats(socketAvailable: socketAvailable, context: context)
            : ProbeResult(value: [], warnings: [], succeeded: false)

        let daemonResult = await daemon
        let containerList = await containers

        var warnings = daemonResult.warnings
        let profileResult = await profiles
        let imageResult = await images
        let volumeResult = await volumes
        let networkResult = await networks
        let statsResult = await stats
        let processResult: ProbeResult<[ContainerProcess]>
        if scope.includeProcesses {
            processResult = await dockerTopProcesses(
                containers: containerList.value,
                socketAvailable: socketAvailable && containerList.succeeded,
                context: context
            )
        } else {
            processResult = ProbeResult(value: [], warnings: [], succeeded: false)
        }
        let profileContexts = Self.profileContexts(from: profileResult.value, context: context)
        let network = daemonResult.value?.status?.network
        let dockerReachable = containerList.succeeded
            || imageResult.succeeded
            || volumeResult.succeeded
            || networkResult.succeeded
            || statsResult.succeeded
        warnings += profileResult.warnings
        warnings += containerList.warnings
        warnings += imageResult.warnings
        warnings += volumeResult.warnings
        warnings += networkResult.warnings
        warnings += statsResult.warnings
        warnings += processResult.warnings
        if scope.includeDockerInventory && !socketAvailable {
            warnings.append("Conjet Docker socket is not available at \(socketPath). Start Conjet to enable container, image, volume, stats, and process views.")
        }
        let activity = ContainerActivitySnapshot(
            containers: containerList.value,
            stats: statsResult.value,
            processes: processResult.value
        )

        return DashboardSnapshot(
            conjetTool: context.conjetTool,
            conjetCoreTool: context.conjetCoreTool,
            dockerTool: context.dockerTool,
            dockerSocketPath: socketPath,
            dockerSocketAvailable: socketAvailable,
            dockerReachable: dockerReachable,
            daemonResponse: daemonResult.value,
            network: network,
            profiles: profileResult.value,
            profileContexts: profileContexts,
            containers: containerList.value,
            images: imageResult.value,
            volumes: volumeResult.value,
            dockerNetworks: networkResult.value,
            stats: statsResult.value,
            containerProcesses: processResult.value,
            containerActivity: activity,
            refreshStatus: DashboardRefreshStatus(
                containersSucceeded: containerList.succeeded,
                imagesSucceeded: imageResult.succeeded,
                volumesSucceeded: volumeResult.succeeded,
                dockerNetworksSucceeded: networkResult.succeeded,
                statsSucceeded: statsResult.succeeded,
                processesSucceeded: processResult.succeeded,
                networkSucceeded: network != nil
            ),
            warnings: Array(warnings.prefix(8))
        )
    }

    public func loadContainers() async -> [DockerContainer] {
        let context = runtime.runtimeContext()
        let socketAvailable = FileManager.default.fileExists(atPath: context.paths.dockerSocket.path)
        return await dockerContainers(socketAvailable: socketAvailable, context: context).value
    }

    public func loadImages() async -> [DockerImage] {
        let context = runtime.runtimeContext()
        let socketAvailable = FileManager.default.fileExists(atPath: context.paths.dockerSocket.path)
        return await dockerImages(socketAvailable: socketAvailable, context: context).value
    }

    public func loadVolumes(includeUsage: Bool = false) async -> [DockerVolume] {
        let context = runtime.runtimeContext()
        let socketAvailable = FileManager.default.fileExists(atPath: context.paths.dockerSocket.path)
        return await dockerVolumes(
            socketAvailable: socketAvailable,
            includeUsage: includeUsage,
            context: context
        ).value
    }

    public func loadDockerNetworks() async -> [DockerNetwork] {
        let context = runtime.runtimeContext()
        let socketAvailable = FileManager.default.fileExists(atPath: context.paths.dockerSocket.path)
        return await dockerNetworks(socketAvailable: socketAvailable, context: context).value
    }

    public func createProfile(named profileName: String) throws -> ConjetProfileStatus {
        try runtime.createProfile(named: profileName)
    }

    public func loadProfileConfig(named profileName: String) throws -> ConjetProfileConfigResult {
        try runtime.profileConfig(named: profileName)
    }

    public func saveProfileConfig(named profileName: String, config: ConjetConfig) throws -> ConjetProfileConfigResult {
        try runtime.saveProfileConfig(named: profileName, config: config)
    }

    public func switchProfile(named profileName: String) throws -> ConjetProfileActivationResult {
        try runtime.switchProfile(named: profileName)
    }

    @available(*, deprecated, message: "Use direct ConjetManagement APIs or runConjetCompatibility for remaining CLI-only flows.")
    public func runConjet(
        _ arguments: [String],
        label: String,
        timeoutSeconds: Double? = 120
    ) async -> CommandLogEntry {
        await runtime.runConjetCompatibility(arguments, label: label, timeoutSeconds: timeoutSeconds)
    }

    public func runConjetCompatibility(
        _ arguments: [String],
        label: String,
        timeoutSeconds: Double? = 120
    ) async -> CommandLogEntry {
        await runtime.runConjetCompatibility(arguments, label: label, timeoutSeconds: timeoutSeconds)
    }

    public func runDocker(
        _ arguments: [String],
        label: String,
        workingDirectory: URL? = nil,
        timeoutSeconds: Double? = 120
    ) async -> CommandLogEntry {
        await runtime.runDocker(
            arguments,
            label: label,
            workingDirectory: workingDirectory,
            timeoutSeconds: timeoutSeconds
        )
    }

    public func runCompose(
        _ arguments: [String],
        workingDirectory: URL,
        label: String,
        timeoutSeconds: Double? = 600
    ) async -> CommandLogEntry {
        await runtime.runCompose(arguments, workingDirectory: workingDirectory, label: label, timeoutSeconds: timeoutSeconds)
    }

    public func dockerExecTerminalCommand(
        container: DockerContainer,
        debugEnabled: Bool = false
    ) throws -> DockerTerminalCommand {
        guard container.isRunning else {
            throw ConjetError.invalidArgument("Container \(container.name) is not running.")
        }
        guard !container.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConjetError.invalidArgument("Container id is missing.")
        }

        let context = runtime.runtimeContext()
        let debugArguments = debugEnabled ? ["--debug"] : []
        let dockerArguments = debugArguments
            + ConjetRuntimeManagementService.dockerHostArguments(paths: context.paths)
            + ["exec", "-it", container.id, "/bin/sh", "-lc", Self.terminalShellBootstrap]
        let arguments = context.dockerTool.argumentsPrefix + dockerArguments
        let terminalEnvironment = Self.terminalEnvironment(from: context.environment)
        let commandLine = Self.terminalShellCommand(
            executable: context.dockerTool.executable,
            arguments: arguments,
            environment: terminalEnvironment
        )

        return DockerTerminalCommand(
            title: "Terminal \(container.name)",
            executable: context.dockerTool.executable,
            arguments: arguments,
            environment: Self.environmentArray(from: terminalEnvironment),
            commandLine: commandLine,
            containerID: container.id,
            containerName: container.name,
            shellPath: "/bin/sh",
            debugEnabled: debugEnabled,
            dockerSocketPath: context.paths.dockerSocket.path
        )
    }

    public func loadVMStatus() async -> DaemonResponse? {
        runtime.freshVMStatus()
    }

    public func streamPulse(
        sinceSequence: UInt64 = 0,
        timeoutSeconds: Double? = nil,
        onFrame: (ConjetPulseFrame) throws -> Bool
    ) throws {
        try runtime.streamPulse(
            sinceSequence: sinceSequence,
            timeoutSeconds: timeoutSeconds,
            onFrame: onFrame
        )
    }

    public func stopRuntime(label: String, timeoutSeconds: Double) async -> CommandLogEntry {
        await runtime.stopRuntimeCommand(timeout: timeoutSeconds, label: label)
    }

    public func stopRuntimeForQuit(daemonTimeoutSeconds: Double, label: String) async -> CommandLogEntry {
        await runtime.stopRuntimeCommand(
            timeout: daemonTimeoutSeconds,
            label: label,
            commandLine: "conjet stop --timeout \(Int(daemonTimeoutSeconds)) --json"
        )
    }

    private func daemonStatus(context: ConjetRuntimeContext) async -> (value: DaemonResponse?, warnings: [String]) {
        (runtime.dashboardDaemonStatus(timeoutSeconds: 2), [])
    }

    private func profileList(context: ConjetRuntimeContext) async -> (value: [String], warnings: [String]) {
        (ConjetRuntimeManagementService.listProfiles(rootHome: context.paths.rootHome), [])
    }

    private static func profileContexts(
        from profiles: [String],
        context: ConjetRuntimeContext
    ) -> [ConjetProfileContext] {
        let current = context.paths.profileName
        let names = Array(Set(profiles + [current])).sorted()
        return names.map { name in
            ConjetProfileContext(
                paths: ConjetPaths(home: context.paths.rootHome, profileName: name),
                isCurrent: name == current
            )
        }
    }

    private func dockerContainers(socketAvailable: Bool, context: ConjetRuntimeContext) async -> ProbeResult<[DockerContainer]> {
        guard socketAvailable else { return ProbeResult(value: [], warnings: [], succeeded: false) }
        let result = await docker(["ps", "-a", "--no-trunc", "--format", "{{json .}}"], timeoutSeconds: 15, context: context)
        guard result.exitCode == 0 else {
            return ProbeResult(value: [], warnings: ["docker ps: \(trim(result.stderr))"], succeeded: false)
        }
        return ProbeResult(
            value: DockerJSONLines.decode(DockerContainer.self, from: result.stdout),
            warnings: [],
            succeeded: true
        )
    }

    private func dockerImages(socketAvailable: Bool, context: ConjetRuntimeContext) async -> ProbeResult<[DockerImage]> {
        guard socketAvailable else { return ProbeResult(value: [], warnings: [], succeeded: false) }
        let result = await docker(["images", "--no-trunc", "--format", "{{json .}}"], timeoutSeconds: 20, context: context)
        guard result.exitCode == 0 else {
            return ProbeResult(value: [], warnings: ["docker images: \(trim(result.stderr))"], succeeded: false)
        }
        return ProbeResult(
            value: deduplicatedImages(DockerJSONLines.decode(DockerImage.self, from: result.stdout)),
            warnings: [],
            succeeded: true
        )
    }

    private func dockerVolumes(
        socketAvailable: Bool,
        includeUsage: Bool = true,
        context: ConjetRuntimeContext
    ) async -> ProbeResult<[DockerVolume]> {
        guard socketAvailable else { return ProbeResult(value: [], warnings: [], succeeded: false) }
        let result = await docker(["volume", "ls", "--format", "{{json .}}"], timeoutSeconds: 20, context: context)
        guard result.exitCode == 0 else {
            return ProbeResult(value: [], warnings: ["docker volume ls: \(trim(result.stderr))"], succeeded: false)
        }
        let volumes = DockerJSONLines.decode(DockerVolume.self, from: result.stdout)
        guard includeUsage else {
            return ProbeResult(value: volumes, warnings: [], succeeded: true)
        }
        let usageResult = await docker(["system", "df", "-v", "--format", "json"], timeoutSeconds: 20, context: context)
        guard usageResult.exitCode == 0 else {
            return ProbeResult(value: volumes, warnings: [], succeeded: true)
        }
        let usageByName = DockerSystemDiskUsage.volumeUsageByName(from: usageResult.stdout)
        return ProbeResult(value: volumes.map { volume in
            guard let usage = usageByName[volume.name] else { return volume }
            var copy = volume
            copy.size = usage.size
            return copy
        }, warnings: [], succeeded: true)
    }

    private func dockerNetworks(socketAvailable: Bool, context: ConjetRuntimeContext) async -> ProbeResult<[DockerNetwork]> {
        guard socketAvailable else { return ProbeResult(value: [], warnings: [], succeeded: false) }
        let result = await docker(["network", "ls", "--no-trunc", "--format", "{{json .}}"], timeoutSeconds: 20, context: context)
        guard result.exitCode == 0 else {
            return ProbeResult(value: [], warnings: ["docker network ls: \(trim(result.stderr))"], succeeded: false)
        }
        return ProbeResult(
            value: DockerJSONLines.decode(DockerNetwork.self, from: result.stdout),
            warnings: [],
            succeeded: true
        )
    }

    private func dockerStats(socketAvailable: Bool, context: ConjetRuntimeContext) async -> ProbeResult<[DockerStats]> {
        guard socketAvailable else { return ProbeResult(value: [], warnings: [], succeeded: false) }
        let result = await docker(["stats", "--no-stream", "--format", "{{json .}}"], timeoutSeconds: 20, context: context)
        guard result.exitCode == 0 else {
            return ProbeResult(value: [], warnings: ["docker stats: \(trim(result.stderr))"], succeeded: false)
        }
        return ProbeResult(
            value: DockerJSONLines.decode(DockerStats.self, from: result.stdout),
            warnings: [],
            succeeded: true
        )
    }

    private func dockerTopProcesses(
        containers: [DockerContainer],
        socketAvailable: Bool,
        context: ConjetRuntimeContext
    ) async -> ProbeResult<[ContainerProcess]> {
        guard socketAvailable else { return ProbeResult(value: [], warnings: [], succeeded: false) }
        let running = containers.filter { $0.state.lowercased() == "running" }
        var processes: [ContainerProcess] = []
        var warnings: [String] = []
        var succeeded = running.isEmpty
        for container in running.prefix(12) {
            let result = await docker(["top", container.id, "-eo", "pid,ppid,user,stat,comm,args"], timeoutSeconds: 8, context: context)
            if result.exitCode != 0 {
                warnings.append("docker top \(container.name): \(trim(result.stderr))")
                continue
            }
            succeeded = true
            processes += parseDockerTop(output: result.stdout, container: container)
        }
        return ProbeResult(value: processes, warnings: warnings, succeeded: succeeded)
    }

    private func docker(_ arguments: [String], timeoutSeconds: Double?, context: ConjetRuntimeContext) async -> ProcessResult {
        await runtime.docker(arguments, timeoutSeconds: timeoutSeconds, context: context)
    }

    private static func terminalEnvironment(from environment: [String: String]) -> [String: String] {
        let keys = [
            "PATH",
            "HOME",
            "USER",
            "LOGNAME",
            "LANG",
            "LC_ALL",
            "LC_CTYPE"
        ] + ConjetEnvironment.runtimeBindingKeys
        var output = keys.reduce(into: [String: String]()) { result, key in
            guard let value = environment[key], !value.isEmpty else { return }
            result[key] = value
        }
        output["TERM"] = "xterm-256color"
        return output
    }

    private static func environmentArray(from environment: [String: String]) -> [String] {
        environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
    }

    private static func terminalShellCommand(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) -> String {
        let assignments = environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(shellQuoted($0.value))" }
        let command = ([executable] + arguments).map(shellQuoted)
        return (assignments + command).joined(separator: " ")
    }

    private static func shellQuoted(_ value: String) -> String {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ shellSafeScalars.contains($0) }) else {
            return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return value
    }

    private static let shellSafeScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")

    private static let terminalShellBootstrap = "if [ -x /bin/bash ]; then exec /bin/bash; fi; if command -v bash >/dev/null 2>&1; then exec bash; fi; exec /bin/sh"

    private func deduplicatedImages(_ images: [DockerImage]) -> [DockerImage] {
        var seen = Set<String>()
        return images.filter { image in
            seen.insert(image.selectionID).inserted
        }
    }

    private func parseDockerTop(output: String, container: DockerContainer) -> [ContainerProcess] {
        output.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 6 else { return nil }
            let command = [parts[4], parts[5]].joined(separator: " ")
            return ContainerProcess(
                containerID: container.id,
                containerName: container.name,
                pid: parts[0],
                ppid: parts[1],
                user: parts[2],
                state: parts[3],
                command: command
            )
        }
    }

    private func trim(_ value: String, limit: Int = 240) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count <= limit { return cleaned }
        return String(cleaned.prefix(limit)) + "..."
    }
}

private struct ProbeResult<Value: Sendable>: Sendable {
    var value: Value
    var warnings: [String]
    var succeeded: Bool
}

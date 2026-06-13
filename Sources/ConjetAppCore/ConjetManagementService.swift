import ConjetCore
import Foundation

public struct ConjetManagementService: Sendable {
    private let baseEnvironment: [String: String]
    private let conjetToolOverride: ResolvedTool?
    private let conjetdToolOverride: ResolvedTool?
    private let dockerToolOverride: ResolvedTool?
    private let persistedRuntimeEnvironmentURL: URL?
    private let execute: @Sendable (CommandInvocation) async -> ProcessResult

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        conjetTool: ResolvedTool? = nil,
        conjetdTool: ResolvedTool? = nil,
        dockerTool: ResolvedTool? = nil,
        includeLaunchdEnvironment: Bool = true,
        persistedRuntimeEnvironmentURL: URL? = nil,
        executor: any CommandExecuting = LocalCommandExecutor()
    ) {
        self.baseEnvironment = ConjetEnvironment.app(
            processEnvironment: environment,
            includeLaunchdEnvironment: includeLaunchdEnvironment,
            includePersistedRuntimeEnvironment: false
        )
        self.conjetToolOverride = conjetTool
        self.conjetdToolOverride = conjetdTool
        self.dockerToolOverride = dockerTool
        self.persistedRuntimeEnvironmentURL = persistedRuntimeEnvironmentURL
        self.execute = { invocation in await executor.run(invocation) }
    }

    public func loadSnapshot() async -> DashboardSnapshot {
        let context = runtimeContext()
        let socketPath = dockerSocketPath(paths: context.paths)
        let socketAvailable = FileManager.default.fileExists(atPath: socketPath)

        async let daemon = daemonStatus(context: context)
        async let profiles = profileList(context: context)
        async let containers = dockerContainers(socketAvailable: socketAvailable, context: context)
        async let images = dockerImages(socketAvailable: socketAvailable, context: context)
        async let volumes = dockerVolumes(socketAvailable: socketAvailable, context: context)
        async let stats = dockerStats(socketAvailable: socketAvailable, context: context)

        let daemonResult = await daemon
        let containerList = await containers
        async let processes = dockerTopProcesses(
            containers: containerList.value,
            socketAvailable: socketAvailable,
            context: context
        )

        var warnings = daemonResult.warnings
        let profileResult = await profiles
        let imageResult = await images
        let volumeResult = await volumes
        let statsResult = await stats
        let processResult = await processes
        let dockerReachable = containerList.succeeded
            || imageResult.succeeded
            || volumeResult.succeeded
            || statsResult.succeeded
        warnings += profileResult.warnings
        warnings += containerList.warnings
        warnings += imageResult.warnings
        warnings += volumeResult.warnings
        warnings += statsResult.warnings
        warnings += processResult.warnings
        if !socketAvailable {
            warnings.append("Conjet Docker socket is not available at \(socketPath). Start Conjet to enable container, image, volume, stats, and process views.")
        }
        let activity = ContainerActivitySnapshot(
            containers: containerList.value,
            stats: statsResult.value,
            processes: processResult.value
        )

        return DashboardSnapshot(
            conjetTool: context.conjetTool,
            conjetdTool: context.conjetdTool,
            dockerTool: context.dockerTool,
            dockerSocketPath: socketPath,
            dockerSocketAvailable: socketAvailable,
            dockerReachable: dockerReachable,
            daemonResponse: daemonResult.value,
            profiles: profileResult.value,
            containers: containerList.value,
            images: imageResult.value,
            volumes: volumeResult.value,
            stats: statsResult.value,
            containerProcesses: processResult.value,
            containerActivity: activity,
            warnings: Array(warnings.prefix(8))
        )
    }

    public func runConjet(
        _ arguments: [String],
        label: String,
        timeoutSeconds: Double? = 120
    ) async -> CommandLogEntry {
        let context = runtimeContext()
        return await run(context.conjetTool.invocation(
            arguments: arguments,
            displayName: label,
            environment: context.environment,
            timeoutSeconds: timeoutSeconds
        ), label: label)
    }

    public func runDocker(
        _ arguments: [String],
        label: String,
        workingDirectory: URL? = nil,
        timeoutSeconds: Double? = 120
    ) async -> CommandLogEntry {
        let context = runtimeContext()
        let invocation = context.dockerTool.invocation(
            arguments: dockerHostArguments(paths: context.paths) + arguments,
            displayName: label,
            workingDirectory: workingDirectory,
            environment: context.environment,
            timeoutSeconds: timeoutSeconds
        )
        return await run(invocation, label: label)
    }

    public func runCompose(
        _ arguments: [String],
        workingDirectory: URL,
        label: String
    ) async -> CommandLogEntry {
        await runDocker(["compose"] + arguments, label: label, workingDirectory: workingDirectory, timeoutSeconds: nil)
    }

    public func loadVMStatus() async -> DaemonResponse? {
        let context = runtimeContext()
        return freshVMStatus(socketPath: nil, context: context)
    }

    private func run(_ invocation: CommandInvocation, label: String) async -> CommandLogEntry {
        let startedAt = Date()
        let result = await execute(invocation)
        let finishedAt = Date()
        return CommandLogEntry(
            label: label,
            commandLine: invocation.commandLine,
            startedAt: startedAt,
            finishedAt: finishedAt,
            exitCode: result.exitCode,
            stdout: result.stdout,
            stderr: result.stderr
        )
    }

    private func daemonStatus(context: RuntimeContext) async -> (value: DaemonResponse?, warnings: [String]) {
        let result = await execute(context.conjetTool.invocation(
            arguments: ["status", "--json"],
            displayName: "Status",
            environment: context.environment,
            timeoutSeconds: 15
        ))
        guard !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (nil, result.stderr.isEmpty ? [] : ["conjet status: \(trim(result.stderr))"])
        }
        do {
            var response = try ConjetJSON.decoder().decode(DaemonResponse.self, from: Data(result.stdout.utf8))
            if let freshResponse = freshVMStatus(socketPath: response.status?.socketPath, context: context) {
                response.status = freshResponse.status ?? response.status
                response.vm = freshResponse.vm ?? freshResponse.status?.vm ?? response.vm
            }
            return (response, result.exitCode == 0 ? [] : ["conjet status exited \(result.exitCode)"])
        } catch {
            return (nil, ["conjet status JSON decode failed: \(error)"])
        }
    }

    private func freshVMStatus(socketPath: String?, context: RuntimeContext) -> DaemonResponse? {
        let path = socketPath ?? daemonSocketPath(paths: context.paths)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try? UnixSocketClient(socketPath: path)
            .send(DaemonRequest(command: .vmStatus), timeoutSeconds: 1)
    }

    private func profileList(context: RuntimeContext) async -> (value: [String], warnings: [String]) {
        let result = await execute(context.conjetTool.invocation(
            arguments: ["profile", "list", "--json"],
            displayName: "Profiles",
            environment: context.environment,
            timeoutSeconds: 10
        ))
        guard result.exitCode == 0 else {
            return ([], ["profile list: \(trim(result.stderr))"])
        }
        do {
            return (try ConjetJSON.decoder().decode([String].self, from: Data(result.stdout.utf8)), [])
        } catch {
            return ([], ["profile list JSON decode failed: \(error)"])
        }
    }

    private func dockerContainers(socketAvailable: Bool, context: RuntimeContext) async -> ProbeResult<[DockerContainer]> {
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

    private func dockerImages(socketAvailable: Bool, context: RuntimeContext) async -> ProbeResult<[DockerImage]> {
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

    private func dockerVolumes(socketAvailable: Bool, context: RuntimeContext) async -> ProbeResult<[DockerVolume]> {
        guard socketAvailable else { return ProbeResult(value: [], warnings: [], succeeded: false) }
        let result = await docker(["volume", "ls", "--format", "{{json .}}"], timeoutSeconds: 20, context: context)
        guard result.exitCode == 0 else {
            return ProbeResult(value: [], warnings: ["docker volume ls: \(trim(result.stderr))"], succeeded: false)
        }
        let volumes = DockerJSONLines.decode(DockerVolume.self, from: result.stdout)
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

    private func dockerStats(socketAvailable: Bool, context: RuntimeContext) async -> ProbeResult<[DockerStats]> {
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
        context: RuntimeContext
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

    private func docker(_ arguments: [String], timeoutSeconds: Double?, context: RuntimeContext) async -> ProcessResult {
        await execute(context.dockerTool.invocation(
            arguments: dockerHostArguments(paths: context.paths) + arguments,
            displayName: "Docker",
            environment: context.environment,
            timeoutSeconds: timeoutSeconds
        ))
    }

    private func dockerHostArguments(paths: ConjetPaths) -> [String] {
        ["--host", "unix://\(dockerSocketPath(paths: paths))"]
    }

    private func dockerSocketPath(paths: ConjetPaths) -> String {
        return paths.dockerSocket.path
    }

    private func daemonSocketPath(paths: ConjetPaths) -> String {
        if let config = try? ConjetConfig.loadOrCreate(paths: paths), let socketPath = config.socketPath {
            return socketPath
        }
        return paths.socket.path
    }

    private func runtimeContext() -> RuntimeContext {
        let environment = ConjetEnvironment.app(
            processEnvironment: baseEnvironment,
            includeLaunchdEnvironment: false,
            persistedRuntimeEnvironmentURL: persistedRuntimeEnvironmentURL
        )
        return RuntimeContext(
            environment: environment,
            conjetTool: conjetToolOverride ?? ConjetToolResolver.conjet(environment: environment),
            conjetdTool: conjetdToolOverride ?? ConjetToolResolver.conjetd(environment: environment),
            dockerTool: dockerToolOverride ?? ConjetToolResolver.docker(environment: environment),
            paths: ConjetPaths.default(environment: environment)
        )
    }

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

private struct RuntimeContext: Sendable {
    var environment: [String: String]
    var conjetTool: ResolvedTool
    var conjetdTool: ResolvedTool
    var dockerTool: ResolvedTool
    var paths: ConjetPaths
}

import ConjetCore
import Foundation

public struct ConjetManagementService: Sendable {
    private let conjetTool: ResolvedTool
    private let conjetdTool: ResolvedTool
    private let dockerTool: ResolvedTool
    private let execute: @Sendable (CommandInvocation) async -> ProcessResult

    public init(
        conjetTool: ResolvedTool = ConjetToolResolver.conjet(),
        conjetdTool: ResolvedTool = ConjetToolResolver.conjetd(),
        dockerTool: ResolvedTool = ConjetToolResolver.docker(),
        executor: any CommandExecuting = LocalCommandExecutor()
    ) {
        self.conjetTool = conjetTool
        self.conjetdTool = conjetdTool
        self.dockerTool = dockerTool
        self.execute = { invocation in await executor.run(invocation) }
    }

    public func loadSnapshot() async -> DashboardSnapshot {
        let socketPath = dockerSocketPath()
        let socketAvailable = FileManager.default.fileExists(atPath: socketPath)

        async let daemon = daemonStatus()
        async let profiles = profileList()
        async let containers = dockerContainers(socketAvailable: socketAvailable)
        async let images = dockerImages(socketAvailable: socketAvailable)
        async let volumes = dockerVolumes(socketAvailable: socketAvailable)
        async let stats = dockerStats(socketAvailable: socketAvailable)

        let daemonResult = await daemon
        let containerList = await containers
        async let processes = dockerTopProcesses(containers: containerList.value, socketAvailable: socketAvailable)

        var warnings = daemonResult.warnings
        let profileResult = await profiles
        let imageResult = await images
        let volumeResult = await volumes
        let statsResult = await stats
        let processResult = await processes
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
            conjetTool: conjetTool,
            conjetdTool: conjetdTool,
            dockerTool: dockerTool,
            dockerSocketPath: socketPath,
            dockerSocketAvailable: socketAvailable,
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
        await run(conjetTool.invocation(arguments: arguments, displayName: label, timeoutSeconds: timeoutSeconds), label: label)
    }

    public func runDocker(
        _ arguments: [String],
        label: String,
        workingDirectory: URL? = nil,
        timeoutSeconds: Double? = 120
    ) async -> CommandLogEntry {
        let invocation = dockerTool.invocation(
            arguments: dockerHostArguments() + arguments,
            displayName: label,
            workingDirectory: workingDirectory,
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
        freshVMStatus(socketPath: nil)
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

    private func daemonStatus() async -> (value: DaemonResponse?, warnings: [String]) {
        let result = await execute(conjetTool.invocation(arguments: ["status", "--json"], displayName: "Status", timeoutSeconds: 15))
        guard !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (nil, result.stderr.isEmpty ? [] : ["conjet status: \(trim(result.stderr))"])
        }
        do {
            var response = try ConjetJSON.decoder().decode(DaemonResponse.self, from: Data(result.stdout.utf8))
            if let freshResponse = freshVMStatus(socketPath: response.status?.socketPath) {
                response.status = freshResponse.status ?? response.status
                response.vm = freshResponse.vm ?? freshResponse.status?.vm ?? response.vm
            }
            return (response, result.exitCode == 0 ? [] : ["conjet status exited \(result.exitCode)"])
        } catch {
            return (nil, ["conjet status JSON decode failed: \(error)"])
        }
    }

    private func freshVMStatus(socketPath: String?) -> DaemonResponse? {
        let path = socketPath ?? daemonSocketPath()
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try? UnixSocketClient(socketPath: path)
            .send(DaemonRequest(command: .vmStatus), timeoutSeconds: 1)
    }

    private func profileList() async -> (value: [String], warnings: [String]) {
        let result = await execute(conjetTool.invocation(arguments: ["profile", "list", "--json"], displayName: "Profiles", timeoutSeconds: 10))
        guard result.exitCode == 0 else {
            return ([], ["profile list: \(trim(result.stderr))"])
        }
        do {
            return (try ConjetJSON.decoder().decode([String].self, from: Data(result.stdout.utf8)), [])
        } catch {
            return ([], ["profile list JSON decode failed: \(error)"])
        }
    }

    private func dockerContainers(socketAvailable: Bool) async -> (value: [DockerContainer], warnings: [String]) {
        guard socketAvailable else { return ([], []) }
        let result = await docker(["ps", "-a", "--no-trunc", "--format", "{{json .}}"], timeoutSeconds: 15)
        guard result.exitCode == 0 else { return ([], ["docker ps: \(trim(result.stderr))"]) }
        return (DockerJSONLines.decode(DockerContainer.self, from: result.stdout), [])
    }

    private func dockerImages(socketAvailable: Bool) async -> (value: [DockerImage], warnings: [String]) {
        guard socketAvailable else { return ([], []) }
        let result = await docker(["images", "--no-trunc", "--format", "{{json .}}"], timeoutSeconds: 20)
        guard result.exitCode == 0 else { return ([], ["docker images: \(trim(result.stderr))"]) }
        return (DockerJSONLines.decode(DockerImage.self, from: result.stdout), [])
    }

    private func dockerVolumes(socketAvailable: Bool) async -> (value: [DockerVolume], warnings: [String]) {
        guard socketAvailable else { return ([], []) }
        let result = await docker(["volume", "ls", "--format", "{{json .}}"], timeoutSeconds: 20)
        guard result.exitCode == 0 else { return ([], ["docker volume ls: \(trim(result.stderr))"]) }
        let volumes = DockerJSONLines.decode(DockerVolume.self, from: result.stdout)
        let usageResult = await docker(["system", "df", "-v", "--format", "json"], timeoutSeconds: 20)
        guard usageResult.exitCode == 0 else { return (volumes, []) }
        let usageByName = DockerSystemDiskUsage.volumeUsageByName(from: usageResult.stdout)
        return (volumes.map { volume in
            guard let usage = usageByName[volume.name] else { return volume }
            var copy = volume
            copy.size = usage.size
            return copy
        }, [])
    }

    private func dockerStats(socketAvailable: Bool) async -> (value: [DockerStats], warnings: [String]) {
        guard socketAvailable else { return ([], []) }
        let result = await docker(["stats", "--no-stream", "--format", "{{json .}}"], timeoutSeconds: 20)
        guard result.exitCode == 0 else { return ([], ["docker stats: \(trim(result.stderr))"]) }
        return (DockerJSONLines.decode(DockerStats.self, from: result.stdout), [])
    }

    private func dockerTopProcesses(
        containers: [DockerContainer],
        socketAvailable: Bool
    ) async -> (value: [ContainerProcess], warnings: [String]) {
        guard socketAvailable else { return ([], []) }
        let running = containers.filter { $0.state.lowercased() == "running" }
        var processes: [ContainerProcess] = []
        var warnings: [String] = []
        for container in running.prefix(12) {
            let result = await docker(["top", container.id, "-eo", "pid,ppid,user,stat,comm,args"], timeoutSeconds: 8)
            if result.exitCode != 0 {
                warnings.append("docker top \(container.name): \(trim(result.stderr))")
                continue
            }
            processes += parseDockerTop(output: result.stdout, container: container)
        }
        return (processes, warnings)
    }

    private func docker(_ arguments: [String], timeoutSeconds: Double?) async -> ProcessResult {
        await execute(dockerTool.invocation(
            arguments: dockerHostArguments() + arguments,
            displayName: "Docker",
            timeoutSeconds: timeoutSeconds
        ))
    }

    private func dockerHostArguments() -> [String] {
        ["--host", "unix://\(dockerSocketPath())"]
    }

    private func dockerSocketPath() -> String {
        let paths = ConjetPaths.default()
        if let config = try? ConjetConfig.loadOrCreate(paths: paths), let socketPath = config.socketPath {
            return socketPath
        }
        return paths.dockerSocket.path
    }

    private func daemonSocketPath() -> String {
        let paths = ConjetPaths.default()
        if let config = try? ConjetConfig.loadOrCreate(paths: paths), let socketPath = config.socketPath {
            return socketPath
        }
        return paths.socket.path
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

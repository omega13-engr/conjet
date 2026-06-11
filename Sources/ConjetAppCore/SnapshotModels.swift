import ConjetCore
import Foundation

public struct ContainerActivitySnapshot: Equatable, Sendable {
    public var totalContainers: Int
    public var runningContainers: Int
    public var stoppedContainers: Int
    public var statsSampleCount: Int
    public var processCount: Int
    public var totalCPUPercent: Double
    public var busiestContainerName: String?
    public var busiestContainerCPUPercent: Double?

    public init(
        totalContainers: Int = 0,
        runningContainers: Int = 0,
        stoppedContainers: Int = 0,
        statsSampleCount: Int = 0,
        processCount: Int = 0,
        totalCPUPercent: Double = 0,
        busiestContainerName: String? = nil,
        busiestContainerCPUPercent: Double? = nil
    ) {
        self.totalContainers = totalContainers
        self.runningContainers = runningContainers
        self.stoppedContainers = stoppedContainers
        self.statsSampleCount = statsSampleCount
        self.processCount = processCount
        self.totalCPUPercent = totalCPUPercent
        self.busiestContainerName = busiestContainerName
        self.busiestContainerCPUPercent = busiestContainerCPUPercent
    }

    public init(
        containers: [DockerContainer],
        stats: [DockerStats],
        processes: [ContainerProcess]
    ) {
        let running = containers.filter { $0.state.localizedCaseInsensitiveContains("running") }.count
        let parsedStats = stats.map { stat in
            (stat, Self.percentValue(from: stat.cpuPercent))
        }
        let busiest = parsedStats.max { $0.1 < $1.1 }

        self.init(
            totalContainers: containers.count,
            runningContainers: running,
            stoppedContainers: max(containers.count - running, 0),
            statsSampleCount: stats.count,
            processCount: processes.count,
            totalCPUPercent: parsedStats.reduce(0) { $0 + $1.1 },
            busiestContainerName: busiest?.0.name,
            busiestContainerCPUPercent: busiest?.1
        )
    }

    public var totalCPUPercentText: String {
        String(format: "%.1f%%", totalCPUPercent)
    }

    public var busiestContainerText: String {
        guard let name = busiestContainerName, let cpu = busiestContainerCPUPercent else {
            return "no running sample"
        }
        return "\(name) \(String(format: "%.1f%%", cpu))"
    }

    private static func percentValue(from value: String) -> Double {
        Double(value.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) ?? 0
    }
}

public struct DashboardSnapshot: Equatable, Sendable {
    public var capturedAt: Date
    public var conjetTool: ResolvedTool
    public var conjetdTool: ResolvedTool
    public var dockerTool: ResolvedTool
    public var dockerSocketPath: String
    public var dockerSocketAvailable: Bool
    public var daemonResponse: DaemonResponse?
    public var profiles: [String]
    public var containers: [DockerContainer]
    public var images: [DockerImage]
    public var volumes: [DockerVolume]
    public var stats: [DockerStats]
    public var containerProcesses: [ContainerProcess]
    public var containerActivity: ContainerActivitySnapshot
    public var warnings: [String]

    public init(
        capturedAt: Date = Date(),
        conjetTool: ResolvedTool,
        conjetdTool: ResolvedTool,
        dockerTool: ResolvedTool,
        dockerSocketPath: String,
        dockerSocketAvailable: Bool,
        daemonResponse: DaemonResponse? = nil,
        profiles: [String] = [],
        containers: [DockerContainer] = [],
        images: [DockerImage] = [],
        volumes: [DockerVolume] = [],
        stats: [DockerStats] = [],
        containerProcesses: [ContainerProcess] = [],
        containerActivity: ContainerActivitySnapshot = ContainerActivitySnapshot(),
        warnings: [String] = []
    ) {
        self.capturedAt = capturedAt
        self.conjetTool = conjetTool
        self.conjetdTool = conjetdTool
        self.dockerTool = dockerTool
        self.dockerSocketPath = dockerSocketPath
        self.dockerSocketAvailable = dockerSocketAvailable
        self.daemonResponse = daemonResponse
        self.profiles = profiles
        self.containers = containers
        self.images = images
        self.volumes = volumes
        self.stats = stats
        self.containerProcesses = containerProcesses
        self.containerActivity = containerActivity
        self.warnings = warnings
    }

    public static func empty(
        conjetTool: ResolvedTool = ConjetToolResolver.conjet(),
        conjetdTool: ResolvedTool = ConjetToolResolver.conjetd(),
        dockerTool: ResolvedTool = ConjetToolResolver.docker(),
        dockerSocketPath: String = ""
    ) -> DashboardSnapshot {
        DashboardSnapshot(
            conjetTool: conjetTool,
            conjetdTool: conjetdTool,
            dockerTool: dockerTool,
            dockerSocketPath: dockerSocketPath,
            dockerSocketAvailable: false
        )
    }
}

public enum ConjetAppFormatters {
    public static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    public static let shortDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()
}

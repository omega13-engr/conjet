import ConjetCore
import ConjetManagement
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

public struct DashboardRefreshStatus: Equatable, Sendable {
    public var containersSucceeded: Bool
    public var imagesSucceeded: Bool
    public var volumesSucceeded: Bool
    public var dockerNetworksSucceeded: Bool
    public var statsSucceeded: Bool
    public var processesSucceeded: Bool
    public var networkSucceeded: Bool

    public init(
        containersSucceeded: Bool = false,
        imagesSucceeded: Bool = false,
        volumesSucceeded: Bool = false,
        dockerNetworksSucceeded: Bool = false,
        statsSucceeded: Bool = false,
        processesSucceeded: Bool = false,
        networkSucceeded: Bool = false
    ) {
        self.containersSucceeded = containersSucceeded
        self.imagesSucceeded = imagesSucceeded
        self.volumesSucceeded = volumesSucceeded
        self.dockerNetworksSucceeded = dockerNetworksSucceeded
        self.statsSucceeded = statsSucceeded
        self.processesSucceeded = processesSucceeded
        self.networkSucceeded = networkSucceeded
    }

    public static let none = DashboardRefreshStatus()
    public static let succeeded = DashboardRefreshStatus(
        containersSucceeded: true,
        imagesSucceeded: true,
        volumesSucceeded: true,
        dockerNetworksSucceeded: true,
        statsSucceeded: true,
        processesSucceeded: true,
        networkSucceeded: true
    )
}

public struct ConjetProfileContext: Identifiable, Equatable, Sendable {
    public var name: String
    public var isCurrent: Bool
    public var rootHomePath: String
    public var homePath: String
    public var configPath: String
    public var runDirectoryPath: String
    public var daemonSocketPath: String
    public var dockerSocketPath: String
    public var logsDirectoryPath: String
    public var daemonLogPath: String
    public var stateDirectoryPath: String
    public var vmManifestPath: String
    public var serialLogPath: String

    public var id: String { name }

    public init(
        name: String,
        isCurrent: Bool = false,
        rootHomePath: String = "",
        homePath: String = "",
        configPath: String = "",
        runDirectoryPath: String = "",
        daemonSocketPath: String = "",
        dockerSocketPath: String = "",
        logsDirectoryPath: String = "",
        daemonLogPath: String = "",
        stateDirectoryPath: String = "",
        vmManifestPath: String = "",
        serialLogPath: String = ""
    ) {
        self.name = name
        self.isCurrent = isCurrent
        self.rootHomePath = rootHomePath
        self.homePath = homePath
        self.configPath = configPath
        self.runDirectoryPath = runDirectoryPath
        self.daemonSocketPath = daemonSocketPath
        self.dockerSocketPath = dockerSocketPath
        self.logsDirectoryPath = logsDirectoryPath
        self.daemonLogPath = daemonLogPath
        self.stateDirectoryPath = stateDirectoryPath
        self.vmManifestPath = vmManifestPath
        self.serialLogPath = serialLogPath
    }

    public init(paths: ConjetPaths, isCurrent: Bool) {
        self.init(
            name: paths.profileName,
            isCurrent: isCurrent,
            rootHomePath: paths.rootHome.path,
            homePath: paths.home.path,
            configPath: paths.config.path,
            runDirectoryPath: paths.runDirectory.path,
            daemonSocketPath: paths.socket.path,
            dockerSocketPath: paths.dockerSocket.path,
            logsDirectoryPath: paths.logsDirectory.path,
            daemonLogPath: paths.daemonLog.path,
            stateDirectoryPath: paths.stateDirectory.path,
            vmManifestPath: paths.vmManifest.path,
            serialLogPath: paths.serialLog.path
        )
    }

    public var statusText: String {
        isCurrent ? "current" : "available"
    }
}

public struct DashboardSnapshot: Equatable, Sendable {
    public var capturedAt: Date
    public var conjetTool: ResolvedTool
    public var conjetCoreTool: ResolvedTool
    public var dockerTool: ResolvedTool
    public var dockerSocketPath: String
    public var dockerSocketAvailable: Bool
    public var dockerReachable: Bool
    public var daemonResponse: DaemonResponse?
    public var network: ConjetNetworkStatus?
    public var profiles: [String]
    public var profileContexts: [ConjetProfileContext]
    public var containers: [DockerContainer]
    public var images: [DockerImage]
    public var volumes: [DockerVolume]
    public var dockerNetworks: [DockerNetwork]
    public var stats: [DockerStats]
    public var containerProcesses: [ContainerProcess]
    public var containerActivity: ContainerActivitySnapshot
    public var refreshStatus: DashboardRefreshStatus
    public var warnings: [String]

    public init(
        capturedAt: Date = Date(),
        conjetTool: ResolvedTool,
        conjetCoreTool: ResolvedTool,
        dockerTool: ResolvedTool,
        dockerSocketPath: String,
        dockerSocketAvailable: Bool,
        dockerReachable: Bool = false,
        daemonResponse: DaemonResponse? = nil,
        network: ConjetNetworkStatus? = nil,
        profiles: [String] = [],
        profileContexts: [ConjetProfileContext] = [],
        containers: [DockerContainer] = [],
        images: [DockerImage] = [],
        volumes: [DockerVolume] = [],
        dockerNetworks: [DockerNetwork] = [],
        stats: [DockerStats] = [],
        containerProcesses: [ContainerProcess] = [],
        containerActivity: ContainerActivitySnapshot = ContainerActivitySnapshot(),
        refreshStatus: DashboardRefreshStatus = .succeeded,
        warnings: [String] = []
    ) {
        self.capturedAt = capturedAt
        self.conjetTool = conjetTool
        self.conjetCoreTool = conjetCoreTool
        self.dockerTool = dockerTool
        self.dockerSocketPath = dockerSocketPath
        self.dockerSocketAvailable = dockerSocketAvailable
        self.dockerReachable = dockerReachable
        self.daemonResponse = daemonResponse
        self.network = network ?? daemonResponse?.status?.network
        self.profiles = profiles.isEmpty ? profileContexts.map(\.name) : profiles
        self.profileContexts = profileContexts.isEmpty
            ? self.profiles.map { ConjetProfileContext(name: $0) }
            : profileContexts
        self.containers = containers
        self.images = images
        self.volumes = volumes
        self.dockerNetworks = dockerNetworks
        self.stats = stats
        self.containerProcesses = containerProcesses
        self.containerActivity = containerActivity
        self.refreshStatus = refreshStatus
        self.warnings = warnings
    }

    public static func empty(
        conjetTool: ResolvedTool = ConjetToolResolver.conjet(),
        conjetCoreTool: ResolvedTool = ConjetToolResolver.conjetCore(),
        dockerTool: ResolvedTool = ConjetToolResolver.docker(),
        dockerSocketPath: String = ""
    ) -> DashboardSnapshot {
        DashboardSnapshot(
            conjetTool: conjetTool,
            conjetCoreTool: conjetCoreTool,
            dockerTool: dockerTool,
            dockerSocketPath: dockerSocketPath,
            dockerSocketAvailable: false,
            dockerReachable: false,
            refreshStatus: .none
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

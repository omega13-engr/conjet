import Foundation

public enum RuntimeState: String, Codable, Equatable, Sendable {
    case cold
    case warmIdle = "warm-idle"
    case devIdle = "dev-idle"
    case interactive
    case build
    case cooldown
    case stopping
}

public enum DaemonCommand: String, Codable, Equatable, Sendable {
    case ping
    case status
    case stop
    case vmStart = "vm-start"
    case vmStop = "vm-stop"
    case vmStatus = "vm-status"
    case dockerRun = "docker-run"
    case networkRepair = "network-repair"
}

public struct DaemonRequest: Codable, Equatable, Sendable {
    public var command: DaemonCommand
    public var parameters: [String: String]
    public var arguments: [String]

    public init(
        command: DaemonCommand,
        parameters: [String: String] = [:],
        arguments: [String] = []
    ) {
        self.command = command
        self.parameters = parameters
        self.arguments = arguments
    }
}

public enum VMRunState: String, Codable, Equatable, Sendable {
    case unconfigured
    case stopped
    case starting
    case running
    case stopping
    case error
}

public struct VMRuntimeStatus: Codable, Equatable, Sendable {
    public var state: VMRunState
    public var configured: Bool
    public var manifestPath: String
    public var bootLoaderKind: String?
    public var bootDiskPath: String?
    public var efiVariableStorePath: String?
    public var cloudInitSeedPath: String?
    public var kernelPath: String?
    public var initialRamdiskPath: String?
    public var rootDiskPath: String?
    public var dataDiskPath: String?
    public var bootstrapSharePath: String?
    public var serialLogPath: String?
    public var dockerSocketPath: String?
    public var message: String

    public init(
        state: VMRunState,
        configured: Bool,
        manifestPath: String,
        bootLoaderKind: String? = nil,
        bootDiskPath: String? = nil,
        efiVariableStorePath: String? = nil,
        cloudInitSeedPath: String? = nil,
        kernelPath: String? = nil,
        initialRamdiskPath: String? = nil,
        rootDiskPath: String? = nil,
        dataDiskPath: String? = nil,
        bootstrapSharePath: String? = nil,
        serialLogPath: String? = nil,
        dockerSocketPath: String? = nil,
        message: String
    ) {
        self.state = state
        self.configured = configured
        self.manifestPath = manifestPath
        self.bootLoaderKind = bootLoaderKind
        self.bootDiskPath = bootDiskPath
        self.efiVariableStorePath = efiVariableStorePath
        self.cloudInitSeedPath = cloudInitSeedPath
        self.kernelPath = kernelPath
        self.initialRamdiskPath = initialRamdiskPath
        self.rootDiskPath = rootDiskPath
        self.dataDiskPath = dataDiskPath
        self.bootstrapSharePath = bootstrapSharePath
        self.serialLogPath = serialLogPath
        self.dockerSocketPath = dockerSocketPath
        self.message = message
    }
}

public struct DockerRunResult: Codable, Equatable, Sendable {
    public var image: String
    public var command: [String]
    public var dockerHost: String
    public var exitCode: Int32?
    public var stdoutTail: String
    public var stderrTail: String

    public init(
        image: String,
        command: [String],
        dockerHost: String,
        exitCode: Int32?,
        stdoutTail: String = "",
        stderrTail: String = ""
    ) {
        self.image = image
        self.command = command
        self.dockerHost = dockerHost
        self.exitCode = exitCode
        self.stdoutTail = stdoutTail
        self.stderrTail = stderrTail
    }
}

public struct DaemonStatus: Codable, Equatable, Sendable {
    public var pid: Int32
    public var startedAt: Date
    public var state: RuntimeState
    public var socketPath: String
    public var host: HostCapabilities
    public var config: ConjetConfig
    public var vm: VMRuntimeStatus?
    public var network: ConjetNetworkStatus?

    public init(
        pid: Int32,
        startedAt: Date,
        state: RuntimeState,
        socketPath: String,
        host: HostCapabilities,
        config: ConjetConfig,
        vm: VMRuntimeStatus? = nil,
        network: ConjetNetworkStatus? = nil
    ) {
        self.pid = pid
        self.startedAt = startedAt
        self.state = state
        self.socketPath = socketPath
        self.host = host
        self.config = config
        self.vm = vm
        self.network = network
    }
}

public struct DaemonResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var message: String
    public var status: DaemonStatus?
    public var vm: VMRuntimeStatus?
    public var dockerRun: DockerRunResult?

    public init(
        ok: Bool,
        message: String,
        status: DaemonStatus? = nil,
        vm: VMRuntimeStatus? = nil,
        dockerRun: DockerRunResult? = nil
    ) {
        self.ok = ok
        self.message = message
        self.status = status
        self.vm = vm
        self.dockerRun = dockerRun
    }
}

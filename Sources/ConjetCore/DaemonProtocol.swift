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
    case clockRepair = "clock-repair"
    case pruneCache = "prune-cache"
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

public struct VMRuntimeEvent: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var phase: String
    public var message: String

    public init(timestamp: Date = Date(), phase: String, message: String) {
        self.timestamp = timestamp
        self.phase = phase
        self.message = message
    }
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
    public var phase: String?
    public var events: [VMRuntimeEvent]

    private enum CodingKeys: String, CodingKey {
        case state
        case configured
        case manifestPath
        case bootLoaderKind
        case bootDiskPath
        case efiVariableStorePath
        case cloudInitSeedPath
        case kernelPath
        case initialRamdiskPath
        case rootDiskPath
        case dataDiskPath
        case bootstrapSharePath
        case serialLogPath
        case dockerSocketPath
        case message
        case phase
        case events
    }

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
        message: String,
        phase: String? = nil,
        events: [VMRuntimeEvent] = []
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
        self.phase = phase
        self.events = events
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.state = try container.decode(VMRunState.self, forKey: .state)
        self.configured = try container.decode(Bool.self, forKey: .configured)
        self.manifestPath = try container.decode(String.self, forKey: .manifestPath)
        self.bootLoaderKind = try container.decodeIfPresent(String.self, forKey: .bootLoaderKind)
        self.bootDiskPath = try container.decodeIfPresent(String.self, forKey: .bootDiskPath)
        self.efiVariableStorePath = try container.decodeIfPresent(String.self, forKey: .efiVariableStorePath)
        self.cloudInitSeedPath = try container.decodeIfPresent(String.self, forKey: .cloudInitSeedPath)
        self.kernelPath = try container.decodeIfPresent(String.self, forKey: .kernelPath)
        self.initialRamdiskPath = try container.decodeIfPresent(String.self, forKey: .initialRamdiskPath)
        self.rootDiskPath = try container.decodeIfPresent(String.self, forKey: .rootDiskPath)
        self.dataDiskPath = try container.decodeIfPresent(String.self, forKey: .dataDiskPath)
        self.bootstrapSharePath = try container.decodeIfPresent(String.self, forKey: .bootstrapSharePath)
        self.serialLogPath = try container.decodeIfPresent(String.self, forKey: .serialLogPath)
        self.dockerSocketPath = try container.decodeIfPresent(String.self, forKey: .dockerSocketPath)
        self.message = try container.decode(String.self, forKey: .message)
        self.phase = try container.decodeIfPresent(String.self, forKey: .phase)
        self.events = try container.decodeIfPresent([VMRuntimeEvent].self, forKey: .events) ?? []
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
    public var memoryPolicy: ConjetMemoryPolicy
    public var vm: VMRuntimeStatus?
    public var network: ConjetNetworkStatus?

    public init(
        pid: Int32,
        startedAt: Date,
        state: RuntimeState,
        socketPath: String,
        host: HostCapabilities,
        config: ConjetConfig,
        memoryPolicy: ConjetMemoryPolicy? = nil,
        vm: VMRuntimeStatus? = nil,
        network: ConjetNetworkStatus? = nil
    ) {
        self.pid = pid
        self.startedAt = startedAt
        self.state = state
        self.socketPath = socketPath
        self.host = host
        self.config = config
        self.memoryPolicy = memoryPolicy ?? config.memoryPolicy
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

public enum DaemonCompatibility {
    public static func isUnsupportedCommandResponse(_ response: DaemonResponse, command: DaemonCommand) -> Bool {
        guard !response.ok else { return false }
        return isUnsupportedCommandMessage(response.message, command: command)
    }

    public static func isUnsupportedCommandMessage(_ message: String, command: DaemonCommand) -> Bool {
        message.contains("Cannot initialize DaemonCommand from invalid String value \(command.rawValue)")
    }
}

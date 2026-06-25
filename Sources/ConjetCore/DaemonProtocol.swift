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
    case dockerCompose = "docker-compose"
    case networkRepair = "network-repair"
    case clockRepair = "clock-repair"
    case pruneCache = "prune-cache"
    case memoryReclaim = "memory-reclaim"
    case memoryHardDrop = "memory-hard-drop"
    case pulseSubscribe = "pulse-subscribe"
}

public enum VMStartWaitMode: String, Codable, Equatable, Sendable {
    case control
    case docker

    public static let requestParameterKey = "wait"

    public init(requestValue: String?) throws {
        guard let requestValue, !requestValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self = .control
            return
        }
        switch requestValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "control", "control-ready", "fast":
            self = .control
        case "docker", "docker-ready", "legacy":
            self = .docker
        default:
            throw ConjetError.invalidArgument("--wait must be control or docker")
        }
    }

    public var daemonParameters: [String: String] {
        [Self.requestParameterKey: rawValue]
    }
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

public struct ConjetBlockRuntimeMetrics: Codable, Equatable, Sendable {
    public var requestCount: UInt64
    public var completedCount: UInt64
    public var failedCount: UInt64
    public var inFlight: Int
    public var highWaterInFlight: Int
    public var highWaterBatchDepth: Int
    public var bytesRead: UInt64
    public var bytesWritten: UInt64
    public var bytesCopied: UInt64
    public var totalLatencyMicros: UInt64
    public var maxLatencyMicros: UInt64
    public var lastLatencyMicros: UInt64

    public init(
        requestCount: UInt64 = 0,
        completedCount: UInt64 = 0,
        failedCount: UInt64 = 0,
        inFlight: Int = 0,
        highWaterInFlight: Int = 0,
        highWaterBatchDepth: Int = 0,
        bytesRead: UInt64 = 0,
        bytesWritten: UInt64 = 0,
        bytesCopied: UInt64 = 0,
        totalLatencyMicros: UInt64 = 0,
        maxLatencyMicros: UInt64 = 0,
        lastLatencyMicros: UInt64 = 0
    ) {
        self.requestCount = requestCount
        self.completedCount = completedCount
        self.failedCount = failedCount
        self.inFlight = inFlight
        self.highWaterInFlight = highWaterInFlight
        self.highWaterBatchDepth = highWaterBatchDepth
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
        self.bytesCopied = bytesCopied
        self.totalLatencyMicros = totalLatencyMicros
        self.maxLatencyMicros = maxLatencyMicros
        self.lastLatencyMicros = lastLatencyMicros
    }
}

public struct VMRuntimeStatus: Codable, Equatable, Sendable {
    public var state: VMRunState
    public var backend: ConjetVMBackend?
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
    public var swapDiskPath: String?
    public var bootstrapSharePath: String?
    public var serialLogPath: String?
    public var dockerSocketPath: String?
    public var message: String
    public var phase: String?
    public var events: [VMRuntimeEvent]
    public var memory: ConjetMemoryRuntimeStatus?
    public var blockMetrics: [String: ConjetBlockRuntimeMetrics]?
    public var dockerRuntimeObservation: ConjetDockerRuntimeObservationSnapshot?

    private enum CodingKeys: String, CodingKey {
        case state
        case backend
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
        case swapDiskPath
        case bootstrapSharePath
        case serialLogPath
        case dockerSocketPath
        case message
        case phase
        case events
        case memory
        case blockMetrics
        case dockerRuntimeObservation
    }

    public init(
        state: VMRunState,
        backend: ConjetVMBackend? = nil,
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
        swapDiskPath: String? = nil,
        bootstrapSharePath: String? = nil,
        serialLogPath: String? = nil,
        dockerSocketPath: String? = nil,
        message: String,
        phase: String? = nil,
        events: [VMRuntimeEvent] = [],
        memory: ConjetMemoryRuntimeStatus? = nil,
        blockMetrics: [String: ConjetBlockRuntimeMetrics]? = nil,
        dockerRuntimeObservation: ConjetDockerRuntimeObservationSnapshot? = nil
    ) {
        self.state = state
        self.backend = backend
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
        self.swapDiskPath = swapDiskPath
        self.bootstrapSharePath = bootstrapSharePath
        self.serialLogPath = serialLogPath
        self.dockerSocketPath = dockerSocketPath
        self.message = message
        self.phase = phase
        self.events = events
        self.memory = memory
        self.blockMetrics = blockMetrics
        self.dockerRuntimeObservation = dockerRuntimeObservation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.state = try container.decode(VMRunState.self, forKey: .state)
        self.backend = try container.decodeIfPresent(ConjetVMBackend.self, forKey: .backend)
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
        self.swapDiskPath = try container.decodeIfPresent(String.self, forKey: .swapDiskPath)
        self.bootstrapSharePath = try container.decodeIfPresent(String.self, forKey: .bootstrapSharePath)
        self.serialLogPath = try container.decodeIfPresent(String.self, forKey: .serialLogPath)
        self.dockerSocketPath = try container.decodeIfPresent(String.self, forKey: .dockerSocketPath)
        self.message = try container.decode(String.self, forKey: .message)
        self.phase = try container.decodeIfPresent(String.self, forKey: .phase)
        self.events = try container.decodeIfPresent([VMRuntimeEvent].self, forKey: .events) ?? []
        self.memory = try container.decodeIfPresent(ConjetMemoryRuntimeStatus.self, forKey: .memory)
        self.blockMetrics = try container.decodeIfPresent(
            [String: ConjetBlockRuntimeMetrics].self,
            forKey: .blockMetrics
        )
        self.dockerRuntimeObservation = try container.decodeIfPresent(
            ConjetDockerRuntimeObservationSnapshot.self,
            forKey: .dockerRuntimeObservation
        )
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

public enum DockerComposeInvocationKind: String, Codable, Equatable, Sendable {
    case dockerPlugin = "docker"
    case dockerCompose = "docker-compose"
}

public struct DockerComposeResult: Codable, Equatable, Sendable {
    public var arguments: [String]
    public var dockerHost: String
    public var executable: String
    public var invocationKind: DockerComposeInvocationKind
    public var exitCode: Int32?
    public var stdoutTail: String
    public var stderrTail: String

    public init(
        arguments: [String],
        dockerHost: String,
        executable: String,
        invocationKind: DockerComposeInvocationKind = .dockerPlugin,
        exitCode: Int32?,
        stdoutTail: String = "",
        stderrTail: String = ""
    ) {
        self.arguments = arguments
        self.dockerHost = dockerHost
        self.executable = executable
        self.invocationKind = invocationKind
        self.exitCode = exitCode
        self.stdoutTail = stdoutTail
        self.stderrTail = stderrTail
    }

    private enum CodingKeys: String, CodingKey {
        case arguments
        case dockerHost
        case executable
        case invocationKind
        case exitCode
        case stdoutTail
        case stderrTail
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.arguments = try container.decode([String].self, forKey: .arguments)
        self.dockerHost = try container.decode(String.self, forKey: .dockerHost)
        self.executable = try container.decode(String.self, forKey: .executable)
        self.invocationKind = try container.decodeIfPresent(
            DockerComposeInvocationKind.self,
            forKey: .invocationKind
        ) ?? DockerComposeResult.legacyInvocationKind(executable: executable)
        self.exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode)
        self.stdoutTail = try container.decodeIfPresent(String.self, forKey: .stdoutTail) ?? ""
        self.stderrTail = try container.decodeIfPresent(String.self, forKey: .stderrTail) ?? ""
    }

    private static func legacyInvocationKind(executable: String) -> DockerComposeInvocationKind {
        URL(fileURLWithPath: executable).lastPathComponent == "docker-compose" ? .dockerCompose : .dockerPlugin
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
    public var dockerCompose: DockerComposeResult?
    public var pulse: ConjetPulseState?
    public var memoryHardDrop: ConjetMemoryHardDropResult?

    public init(
        ok: Bool,
        message: String,
        status: DaemonStatus? = nil,
        vm: VMRuntimeStatus? = nil,
        dockerRun: DockerRunResult? = nil,
        dockerCompose: DockerComposeResult? = nil,
        pulse: ConjetPulseState? = nil,
        memoryHardDrop: ConjetMemoryHardDropResult? = nil
    ) {
        self.ok = ok
        self.message = message
        self.status = status
        self.vm = vm
        self.dockerRun = dockerRun
        self.dockerCompose = dockerCompose
        self.pulse = pulse
        self.memoryHardDrop = memoryHardDrop
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

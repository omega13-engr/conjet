import Foundation

public enum ConjetEnergyMode: String, Codable, CaseIterable, Sendable {
    case performance
    case balanced
    case eco
}

public enum ConjetMemoryProfile: String, Codable, CaseIterable, Sendable {
    case noPolicy = "no-policy"
    case performance
    case balanced
    case eco

    public static func parse(_ value: String) -> ConjetMemoryProfile? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "default", "none", "no-policy", "nopolicy", "no_policy":
            return .noPolicy
        case "performance", "balanced", "eco":
            return ConjetMemoryProfile(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        default:
            return nil
        }
    }

    public static var allowedValuesDescription: String {
        "no-policy, performance, balanced, or eco"
    }
}

public enum ConjetVMProfile: String, Codable, CaseIterable, Sendable {
    case dockerCompatibility = "docker-compatibility"
    case pulseFast = "pulse-fast"

    public static func parse(_ value: String) -> ConjetVMProfile? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "docker", "docker-compat", "docker-compatibility", "compatibility":
            return .dockerCompatibility
        case "pulse", "pulse-fast", "fast":
            return .pulseFast
        default:
            return nil
        }
    }

    public static var allowedValuesDescription: String {
        "docker-compatibility or pulse-fast"
    }
}

public enum ConjetContainerRuntimeKind: String, Codable, CaseIterable, Sendable {
    case docker
    case ociDirect = "oci-direct"

    public static func parse(_ value: String) -> ConjetContainerRuntimeKind? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "docker":
            return .docker
        case "oci", "oci-direct", "direct-oci", "pulse":
            return .ociDirect
        default:
            return nil
        }
    }

    public static var allowedValuesDescription: String {
        "docker or oci-direct"
    }

    public var requiresPublishedConjetCoreImage: Bool {
        self == .docker
    }
}

public enum ConjetVMBackend: String, Codable, CaseIterable, Sendable {
    case vz
    case hvfExperimental = "hvf-experimental"

    public var displayName: String {
        switch self {
        case .vz:
            return "VZ Rosetta fallback"
        case .hvfExperimental:
            return "Jetstream HVF primary"
        }
    }

    public var isExperimental: Bool {
        self == .hvfExperimental
    }

    public var startSupported: Bool {
        switch self {
        case .vz, .hvfExperimental:
            return true
        }
    }

    public var appleVirtualMachineServiceExpected: Bool {
        self == .vz
    }

    public var rosettaPolicy: String {
        switch self {
        case .vz:
            return "available through Virtualization.framework when installed"
        case .hvfExperimental:
            return "arm64-only until public Rosetta support exists outside VZ"
        }
    }

    public var performanceLane: String {
        switch self {
        case .vz:
            return "compatibility"
        case .hvfExperimental:
            return "jetstream"
        }
    }

    public static func parse(_ value: String) -> ConjetVMBackend? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "vz", "virtualization", "virtualization-framework":
            return .vz
        case "hvf", "hypervisor", "hypervisor-framework", "hvf-experimental", "jetstream", "jetstream-hvf":
            return .hvfExperimental
        default:
            return nil
        }
    }

    public static var allowedValuesDescription: String {
        "vz or hvf-experimental"
    }
}

public struct ConjetVMBackendSelectionStatus: Codable, Equatable, Sendable {
    public var selected: ConjetVMBackend
    public var active: ConjetVMBackend?
    public var effective: ConjetVMBackend
    public var requiresCoreRestart: Bool
    public var startSupported: Bool
    public var appleVirtualMachineServiceExpected: Bool
    public var rosettaPolicy: String
    public var performanceLane: String
    public var message: String

    public init(selected: ConjetVMBackend, active: ConjetVMBackend? = nil) {
        self.selected = selected
        self.active = active
        self.effective = active ?? selected
        self.requiresCoreRestart = active != nil && active != selected
        self.startSupported = effective.startSupported
        self.appleVirtualMachineServiceExpected = effective.appleVirtualMachineServiceExpected
        self.rosettaPolicy = effective.rosettaPolicy
        self.performanceLane = effective.performanceLane

        if requiresCoreRestart {
            self.message = "Conjet Core is still running with \(effective.rawValue); restart Conjet Core to use \(selected.rawValue)."
        } else if effective == .hvfExperimental {
            self.message = "Jetstream HVF is selected as the primary Conjet Core backend. Direct-kernel guest start is available for the custom VMM lane."
        } else {
            self.message = "VZ backend is selected as the Rosetta and compatibility fallback."
        }
    }
}

public struct ConjetProfileMemoryBounds: Codable, Equatable, Sendable {
    public static let minimumMiB = 2048
    public static let preferredMaximumMiB = 16_384
    public static let constrainedMaximumMiB = 8192

    public var hostMemoryMiB: Int
    public var minimumMiB: Int
    public var maximumMiB: Int

    public init(hostMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        let hostMemoryMiB = Int(hostMemoryBytes / 1_048_576)
        self.init(hostMemoryMiB: hostMemoryMiB)
    }

    public init(hostMemoryMiB: Int) {
        self.hostMemoryMiB = max(0, hostMemoryMiB)
        self.minimumMiB = Self.minimumMiB
        if hostMemoryMiB > 0, hostMemoryMiB <= Self.preferredMaximumMiB {
            self.maximumMiB = Self.constrainedMaximumMiB
        } else {
            self.maximumMiB = Self.preferredMaximumMiB
        }
        self.maximumMiB = max(self.minimumMiB, self.maximumMiB)
    }

    public var minimumGiB: Int {
        minimumMiB / 1024
    }

    public var maximumGiB: Int {
        maximumMiB / 1024
    }

    public var isMaximumConstrainedByHost: Bool {
        maximumMiB < Self.preferredMaximumMiB
    }

    public func clampedMiB(_ value: Int) -> Int {
        min(maximumMiB, max(minimumMiB, roundedToGiBMiB(value)))
    }

    public func miB(forGiB value: Int) -> Int {
        clampedMiB(value * 1024)
    }

    private func roundedToGiBMiB(_ value: Int) -> Int {
        guard value > 0 else {
            return minimumMiB
        }
        let quantum = 1024
        let rounded = Int((Double(value) / Double(quantum)).rounded()) * quantum
        return max(quantum, rounded)
    }
}

public struct ConjetMemoryPolicy: Codable, Equatable, Sendable {
    public var profile: ConjetMemoryProfile
    public var configuredMemoryMiB: Int
    public var recommendedMemoryMiB: Int
    public var lazyRuntimeServices: Bool
    public var lazyNetworkHelpers: Bool
    public var reclaimIdleHelpersAfterSeconds: Int
    public var idleWakeupBudgetPerSecond: Double
    public var automaticIdleMemoryReclaim: Bool
    public var idleMemoryReclaimTargetMiB: Int
    public var idleMemoryReclaimDwellSeconds: Double
    public var dynamicMemoryEnabled: Bool
    public var dynamicMemoryMinimumMiB: Int
    public var dynamicMemoryBaseOverheadMiB: Int
    public var dynamicMemoryHeadroomMiB: Int
    public var dynamicMemoryHeadroomRatio: Double
    public var dynamicMemoryCacheAllowanceMiB: Int
    public var dynamicMemoryShrinkCooldownSeconds: Int
    public var dynamicMemoryShrinkStepMiB: Int

    private enum CodingKeys: String, CodingKey {
        case profile
        case configuredMemoryMiB
        case recommendedMemoryMiB
        case lazyRuntimeServices
        case lazyNetworkHelpers
        case reclaimIdleHelpersAfterSeconds
        case idleWakeupBudgetPerSecond
        case automaticIdleMemoryReclaim
        case idleMemoryReclaimTargetMiB
        case idleMemoryReclaimDwellSeconds
        case dynamicMemoryEnabled
        case dynamicMemoryMinimumMiB
        case dynamicMemoryBaseOverheadMiB
        case dynamicMemoryHeadroomMiB
        case dynamicMemoryHeadroomRatio
        case dynamicMemoryCacheAllowanceMiB
        case dynamicMemoryShrinkCooldownSeconds
        case dynamicMemoryShrinkStepMiB
    }

    public init(
        profile: ConjetMemoryProfile,
        configuredMemoryMiB: Int,
        recommendedMemoryMiB: Int,
        lazyRuntimeServices: Bool,
        lazyNetworkHelpers: Bool,
        reclaimIdleHelpersAfterSeconds: Int,
        idleWakeupBudgetPerSecond: Double,
        automaticIdleMemoryReclaim: Bool,
        idleMemoryReclaimTargetMiB: Int,
        idleMemoryReclaimDwellSeconds: Double,
        dynamicMemoryEnabled: Bool,
        dynamicMemoryMinimumMiB: Int,
        dynamicMemoryBaseOverheadMiB: Int,
        dynamicMemoryHeadroomMiB: Int,
        dynamicMemoryHeadroomRatio: Double,
        dynamicMemoryCacheAllowanceMiB: Int,
        dynamicMemoryShrinkCooldownSeconds: Int,
        dynamicMemoryShrinkStepMiB: Int
    ) {
        self.profile = profile
        self.configuredMemoryMiB = configuredMemoryMiB
        self.recommendedMemoryMiB = recommendedMemoryMiB
        self.lazyRuntimeServices = lazyRuntimeServices
        self.lazyNetworkHelpers = lazyNetworkHelpers
        self.reclaimIdleHelpersAfterSeconds = reclaimIdleHelpersAfterSeconds
        self.idleWakeupBudgetPerSecond = idleWakeupBudgetPerSecond
        self.automaticIdleMemoryReclaim = automaticIdleMemoryReclaim
        self.idleMemoryReclaimTargetMiB = idleMemoryReclaimTargetMiB
        self.idleMemoryReclaimDwellSeconds = idleMemoryReclaimDwellSeconds
        self.dynamicMemoryEnabled = dynamicMemoryEnabled
        self.dynamicMemoryMinimumMiB = dynamicMemoryMinimumMiB
        self.dynamicMemoryBaseOverheadMiB = dynamicMemoryBaseOverheadMiB
        self.dynamicMemoryHeadroomMiB = dynamicMemoryHeadroomMiB
        self.dynamicMemoryHeadroomRatio = dynamicMemoryHeadroomRatio
        self.dynamicMemoryCacheAllowanceMiB = dynamicMemoryCacheAllowanceMiB
        self.dynamicMemoryShrinkCooldownSeconds = dynamicMemoryShrinkCooldownSeconds
        self.dynamicMemoryShrinkStepMiB = dynamicMemoryShrinkStepMiB
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let profile = try container.decode(ConjetMemoryProfile.self, forKey: .profile)
        let configuredMemoryMiB = try container.decode(Int.self, forKey: .configuredMemoryMiB)
        let target = try container.decodeIfPresent(Int.self, forKey: .idleMemoryReclaimTargetMiB)
            ?? Self.defaultIdleMemoryReclaimTargetMiB(profile: profile, configuredMemoryMiB: configuredMemoryMiB)
        self.init(
            profile: profile,
            configuredMemoryMiB: configuredMemoryMiB,
            recommendedMemoryMiB: try container.decode(Int.self, forKey: .recommendedMemoryMiB),
            lazyRuntimeServices: try container.decode(Bool.self, forKey: .lazyRuntimeServices),
            lazyNetworkHelpers: try container.decode(Bool.self, forKey: .lazyNetworkHelpers),
            reclaimIdleHelpersAfterSeconds: try container.decode(Int.self, forKey: .reclaimIdleHelpersAfterSeconds),
            idleWakeupBudgetPerSecond: try container.decode(Double.self, forKey: .idleWakeupBudgetPerSecond),
            automaticIdleMemoryReclaim: try container.decodeIfPresent(Bool.self, forKey: .automaticIdleMemoryReclaim)
                ?? Self.defaultAutomaticIdleMemoryReclaim(
                    profile: profile,
                    configuredMemoryMiB: configuredMemoryMiB,
                    targetMemoryMiB: target
            ),
            idleMemoryReclaimTargetMiB: target,
            idleMemoryReclaimDwellSeconds: try container.decodeIfPresent(Double.self, forKey: .idleMemoryReclaimDwellSeconds)
                ?? Self.defaultIdleMemoryReclaimDwellSeconds(profile: profile),
            dynamicMemoryEnabled: try container.decodeIfPresent(Bool.self, forKey: .dynamicMemoryEnabled)
                ?? Self.defaultDynamicMemoryEnabled(profile: profile),
            dynamicMemoryMinimumMiB: try container.decodeIfPresent(Int.self, forKey: .dynamicMemoryMinimumMiB)
                ?? Self.defaultDynamicMemoryMinimumMiB(profile: profile, configuredMemoryMiB: configuredMemoryMiB),
            dynamicMemoryBaseOverheadMiB: try container.decodeIfPresent(Int.self, forKey: .dynamicMemoryBaseOverheadMiB)
                ?? Self.defaultDynamicMemoryBaseOverheadMiB(profile: profile, configuredMemoryMiB: configuredMemoryMiB),
            dynamicMemoryHeadroomMiB: try container.decodeIfPresent(Int.self, forKey: .dynamicMemoryHeadroomMiB)
                ?? Self.defaultDynamicMemoryHeadroomMiB(profile: profile, configuredMemoryMiB: configuredMemoryMiB),
            dynamicMemoryHeadroomRatio: try container.decodeIfPresent(Double.self, forKey: .dynamicMemoryHeadroomRatio)
                ?? Self.defaultDynamicMemoryHeadroomRatio(profile: profile),
            dynamicMemoryCacheAllowanceMiB: try container.decodeIfPresent(Int.self, forKey: .dynamicMemoryCacheAllowanceMiB)
                ?? Self.defaultDynamicMemoryCacheAllowanceMiB(profile: profile, configuredMemoryMiB: configuredMemoryMiB),
            dynamicMemoryShrinkCooldownSeconds: try container.decodeIfPresent(Int.self, forKey: .dynamicMemoryShrinkCooldownSeconds)
                ?? Self.defaultDynamicMemoryShrinkCooldownSeconds(profile: profile, configuredMemoryMiB: configuredMemoryMiB),
            dynamicMemoryShrinkStepMiB: try container.decodeIfPresent(Int.self, forKey: .dynamicMemoryShrinkStepMiB)
                ?? Self.defaultDynamicMemoryShrinkStepMiB(profile: profile, configuredMemoryMiB: configuredMemoryMiB)
        )
    }

    private static func roundedUpMiB(_ value: Int, quantum: Int) -> Int {
        guard quantum > 1 else {
            return value
        }
        return ((value + quantum - 1) / quantum) * quantum
    }

    private static func scaledMemoryMiB(
        configuredMemoryMiB: Int,
        ratio: Double,
        minimum: Int,
        maximum: Int,
        quantum: Int = 128
    ) -> Int {
        let scaled = Int((Double(configuredMemoryMiB) * ratio).rounded(.up))
        let rounded = roundedUpMiB(scaled, quantum: quantum)
        return min(configuredMemoryMiB, min(maximum, max(minimum, rounded)))
    }

    public static func defaultIdleMemoryReclaimTargetMiB(
        profile: ConjetMemoryProfile,
        configuredMemoryMiB: Int
    ) -> Int {
        configuredMemoryMiB
    }

    public static func defaultIdleMemoryReclaimDwellSeconds(profile: ConjetMemoryProfile) -> Double {
        0
    }

    public static func defaultAutomaticIdleMemoryReclaim(
        profile: ConjetMemoryProfile,
        configuredMemoryMiB: Int,
        targetMemoryMiB: Int
    ) -> Bool {
        true
    }

    public static func defaultDynamicMemoryEnabled(profile: ConjetMemoryProfile) -> Bool {
        true
    }

    public static func defaultDynamicMemoryMinimumMiB(
        profile: ConjetMemoryProfile,
        configuredMemoryMiB: Int
    ) -> Int {
        scaledMemoryMiB(
            configuredMemoryMiB: configuredMemoryMiB,
            ratio: 0.125,
            minimum: 512,
            maximum: 2048,
            quantum: 128
        )
    }

    public static func defaultDynamicMemoryBaseOverheadMiB(
        profile: ConjetMemoryProfile,
        configuredMemoryMiB: Int
    ) -> Int {
        scaledMemoryMiB(
            configuredMemoryMiB: configuredMemoryMiB,
            ratio: 1.0 / 16.0,
            minimum: 256,
            maximum: 1024
        )
    }

    public static func defaultDynamicMemoryHeadroomMiB(
        profile: ConjetMemoryProfile,
        configuredMemoryMiB: Int
    ) -> Int {
        scaledMemoryMiB(
            configuredMemoryMiB: configuredMemoryMiB,
            ratio: 1.0 / 16.0,
            minimum: 256,
            maximum: 1024
        )
    }

    public static func defaultDynamicMemoryHeadroomRatio(profile: ConjetMemoryProfile) -> Double {
        0.25
    }

    public static func defaultDynamicMemoryCacheAllowanceMiB(
        profile: ConjetMemoryProfile,
        configuredMemoryMiB: Int
    ) -> Int {
        scaledMemoryMiB(
            configuredMemoryMiB: configuredMemoryMiB,
            ratio: 1.0 / 32.0,
            minimum: 128,
            maximum: 512,
            quantum: 128
        )
    }

    public static func defaultDynamicMemoryShrinkCooldownSeconds(
        profile: ConjetMemoryProfile,
        configuredMemoryMiB: Int
    ) -> Int {
        0
    }

    public static func defaultDynamicMemoryShrinkStepMiB(
        profile: ConjetMemoryProfile,
        configuredMemoryMiB: Int
    ) -> Int {
        configuredMemoryMiB
    }

    public static func defaultDynamicMemoryBaseOverheadMiB(profile: ConjetMemoryProfile) -> Int {
        defaultDynamicMemoryBaseOverheadMiB(profile: profile, configuredMemoryMiB: 8192)
    }

    public static func defaultDynamicMemoryHeadroomMiB(profile: ConjetMemoryProfile) -> Int {
        defaultDynamicMemoryHeadroomMiB(profile: profile, configuredMemoryMiB: 8192)
    }

    public static func defaultDynamicMemoryCacheAllowanceMiB(profile: ConjetMemoryProfile) -> Int {
        defaultDynamicMemoryCacheAllowanceMiB(profile: profile, configuredMemoryMiB: 8192)
    }

    public static func defaultDynamicMemoryShrinkCooldownSeconds(profile: ConjetMemoryProfile) -> Int {
        defaultDynamicMemoryShrinkCooldownSeconds(profile: profile, configuredMemoryMiB: 8192)
    }

    public static func defaultDynamicMemoryShrinkStepMiB(profile: ConjetMemoryProfile) -> Int {
        defaultDynamicMemoryShrinkStepMiB(profile: profile, configuredMemoryMiB: 8192)
    }
}

public struct ConjetSSHPolicy: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var transport: String
    public var allowTCPFallback: Bool

    public init(
        enabled: Bool = true,
        transport: String = "proxy-command",
        allowTCPFallback: Bool = false
    ) {
        self.enabled = enabled
        self.transport = transport
        self.allowTCPFallback = allowTCPFallback
    }
}

public struct ConjetConfig: Codable, Equatable, Sendable {
    public var vmCPUs: Int
    public var memoryMiB: Int
    public var vmProfile: ConjetVMProfile
    public var architecture: String
    public var diskGiB: Int
    public var diskImagePath: String?
    public var kernelImagePath: String?
    public var runtime: String
    public var vmBackend: ConjetVMBackend
    public var quietStopMinutes: Int
    public var enableRosetta: Bool
    public var enableHostMounts: Bool
    public var enableRemovableHostMounts: Bool
    public var socketPath: String?
    public var conjetCoreRepository: String
    public var networkBindPolicy: ConjetNetworkBindPolicy
    public var networkProxyEngine: ConjetNetworkProxyEngine
    public var networkBridgeEngine: ConjetNetworkBridgeEngine
    public var networkLANAllowedCIDRs: [String]
    public var networkLANAllowedPorts: [Int]
    public var energyMode: ConjetEnergyMode
    public var memoryProfile: ConjetMemoryProfile
    public var ssh: ConjetSSHPolicy

    public init(
        vmCPUs: Int = 2,
        memoryMiB: Int = 4096,
        vmProfile: ConjetVMProfile = .dockerCompatibility,
        architecture: String = "aarch64",
        diskGiB: Int = 100,
        diskImagePath: String? = nil,
        kernelImagePath: String? = nil,
        runtime: String = "docker",
        vmBackend: ConjetVMBackend,
        quietStopMinutes: Int = 30,
        enableRosetta: Bool = true,
        enableHostMounts: Bool = true,
        enableRemovableHostMounts: Bool = false,
        socketPath: String? = nil,
        conjetCoreRepository: String = ConjetCoreReleaseSource.defaultRepository,
        networkBindPolicy: ConjetNetworkBindPolicy = .secureLocal,
        networkProxyEngine: ConjetNetworkProxyEngine = .auto,
        networkBridgeEngine: ConjetNetworkBridgeEngine = .conjetNetdC,
        networkLANAllowedCIDRs: [String] = [],
        networkLANAllowedPorts: [Int] = [],
        energyMode: ConjetEnergyMode = .balanced,
        memoryProfile: ConjetMemoryProfile = .noPolicy,
        ssh: ConjetSSHPolicy = ConjetSSHPolicy()
    ) {
        self.vmCPUs = vmCPUs
        self.memoryMiB = memoryMiB
        self.vmProfile = vmProfile
        self.architecture = architecture
        self.diskGiB = diskGiB
        self.diskImagePath = diskImagePath
        self.kernelImagePath = kernelImagePath
        self.runtime = runtime
        self.vmBackend = vmBackend
        self.quietStopMinutes = quietStopMinutes
        self.enableRosetta = enableRosetta
        self.enableHostMounts = enableHostMounts
        self.enableRemovableHostMounts = enableRemovableHostMounts
        self.socketPath = socketPath
        self.conjetCoreRepository = conjetCoreRepository
        self.networkBindPolicy = networkBindPolicy
        self.networkProxyEngine = networkProxyEngine
        self.networkBridgeEngine = networkBridgeEngine
        self.networkLANAllowedCIDRs = networkLANAllowedCIDRs
        self.networkLANAllowedPorts = networkLANAllowedPorts
        self.energyMode = energyMode
        self.memoryProfile = memoryProfile
        self.ssh = ssh
    }

    public init(
        vmCPUs: Int = 2,
        memoryMiB: Int = 4096,
        vmProfile: ConjetVMProfile = .dockerCompatibility,
        architecture: String = "aarch64",
        diskGiB: Int = 100,
        diskImagePath: String? = nil,
        kernelImagePath: String? = nil,
        runtime: String = "docker",
        quietStopMinutes: Int = 30,
        enableRosetta: Bool = true,
        enableHostMounts: Bool = true,
        enableRemovableHostMounts: Bool = false,
        socketPath: String? = nil,
        conjetCoreRepository: String = ConjetCoreReleaseSource.defaultRepository,
        networkBindPolicy: ConjetNetworkBindPolicy = .secureLocal,
        networkProxyEngine: ConjetNetworkProxyEngine = .auto,
        networkBridgeEngine: ConjetNetworkBridgeEngine = .conjetNetdC,
        networkLANAllowedCIDRs: [String] = [],
        networkLANAllowedPorts: [Int] = [],
        energyMode: ConjetEnergyMode = .balanced,
        memoryProfile: ConjetMemoryProfile = .noPolicy,
        ssh: ConjetSSHPolicy = ConjetSSHPolicy()
    ) {
        self.init(
            vmCPUs: vmCPUs,
            memoryMiB: memoryMiB,
            vmProfile: vmProfile,
            architecture: architecture,
            diskGiB: diskGiB,
            diskImagePath: diskImagePath,
            kernelImagePath: kernelImagePath,
            runtime: runtime,
            vmBackend: .hvfExperimental,
            quietStopMinutes: quietStopMinutes,
            enableRosetta: enableRosetta,
            enableHostMounts: enableHostMounts,
            enableRemovableHostMounts: enableRemovableHostMounts,
            socketPath: socketPath,
            conjetCoreRepository: conjetCoreRepository,
            networkBindPolicy: networkBindPolicy,
            networkProxyEngine: networkProxyEngine,
            networkBridgeEngine: networkBridgeEngine,
            networkLANAllowedCIDRs: networkLANAllowedCIDRs,
            networkLANAllowedPorts: networkLANAllowedPorts,
            energyMode: energyMode,
            memoryProfile: memoryProfile,
            ssh: ssh
        )
    }

    public static let `default` = ConjetConfig(
        vmCPUs: 2,
        memoryMiB: 4096,
        vmProfile: .dockerCompatibility,
        networkBridgeEngine: .conjetNetdC,
        memoryProfile: .noPolicy
    )

    public var containerRuntime: ConjetContainerRuntimeKind {
        ConjetContainerRuntimeKind.parse(runtime) ?? .docker
    }

    public func validatedContainerRuntime() throws -> ConjetContainerRuntimeKind {
        guard let runtime = ConjetContainerRuntimeKind.parse(runtime) else {
            throw ConjetError.decoding("vm.runtime must be \(ConjetContainerRuntimeKind.allowedValuesDescription)")
        }
        return runtime
    }

    private enum CodingKeys: String, CodingKey {
        case vmCPUs
        case memoryMiB
        case vmProfile
        case architecture
        case diskGiB
        case diskImagePath
        case kernelImagePath
        case runtime
        case vmBackend
        case quietStopMinutes
        case enableRosetta
        case enableHostMounts
        case enableRemovableHostMounts
        case socketPath
        case conjetCoreRepository
        case networkBindPolicy
        case networkProxyEngine
        case networkBridgeEngine
        case networkLANAllowedCIDRs
        case networkLANAllowedPorts
        case energyMode
        case memoryProfile
        case ssh
    }

    public init(from decoder: Decoder) throws {
        let defaults = ConjetConfig.default
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedRuntime = try container.decodeIfPresent(String.self, forKey: .runtime) ?? defaults.runtime
        guard let runtime = ConjetContainerRuntimeKind.parse(decodedRuntime) else {
            throw DecodingError.dataCorruptedError(
                forKey: .runtime,
                in: container,
                debugDescription: "vm.runtime must be \(ConjetContainerRuntimeKind.allowedValuesDescription)"
            )
        }
        self.init(
            vmCPUs: try container.decodeIfPresent(Int.self, forKey: .vmCPUs) ?? defaults.vmCPUs,
            memoryMiB: try container.decodeIfPresent(Int.self, forKey: .memoryMiB) ?? defaults.memoryMiB,
            vmProfile: try container.decodeIfPresent(ConjetVMProfile.self, forKey: .vmProfile) ?? defaults.vmProfile,
            architecture: try container.decodeIfPresent(String.self, forKey: .architecture) ?? defaults.architecture,
            diskGiB: try container.decodeIfPresent(Int.self, forKey: .diskGiB) ?? defaults.diskGiB,
            diskImagePath: try container.decodeIfPresent(String.self, forKey: .diskImagePath) ?? defaults.diskImagePath,
            kernelImagePath: try container.decodeIfPresent(String.self, forKey: .kernelImagePath) ?? defaults.kernelImagePath,
            runtime: runtime.rawValue,
            vmBackend: try container.decodeIfPresent(ConjetVMBackend.self, forKey: .vmBackend) ?? defaults.vmBackend,
            quietStopMinutes: try container.decodeIfPresent(Int.self, forKey: .quietStopMinutes) ?? defaults.quietStopMinutes,
            enableRosetta: try container.decodeIfPresent(Bool.self, forKey: .enableRosetta) ?? defaults.enableRosetta,
            enableHostMounts: try container.decodeIfPresent(Bool.self, forKey: .enableHostMounts) ?? defaults.enableHostMounts,
            enableRemovableHostMounts: try container.decodeIfPresent(Bool.self, forKey: .enableRemovableHostMounts) ?? defaults.enableRemovableHostMounts,
            socketPath: try container.decodeIfPresent(String.self, forKey: .socketPath) ?? defaults.socketPath,
            conjetCoreRepository: try container.decodeIfPresent(String.self, forKey: .conjetCoreRepository) ?? defaults.conjetCoreRepository,
            networkBindPolicy: try container.decodeIfPresent(ConjetNetworkBindPolicy.self, forKey: .networkBindPolicy) ?? defaults.networkBindPolicy,
            networkProxyEngine: try container.decodeIfPresent(ConjetNetworkProxyEngine.self, forKey: .networkProxyEngine) ?? defaults.networkProxyEngine,
            networkBridgeEngine: try container.decodeIfPresent(ConjetNetworkBridgeEngine.self, forKey: .networkBridgeEngine) ?? defaults.networkBridgeEngine,
            networkLANAllowedCIDRs: try container.decodeIfPresent([String].self, forKey: .networkLANAllowedCIDRs) ?? defaults.networkLANAllowedCIDRs,
            networkLANAllowedPorts: try container.decodeIfPresent([Int].self, forKey: .networkLANAllowedPorts) ?? defaults.networkLANAllowedPorts,
            energyMode: try container.decodeIfPresent(ConjetEnergyMode.self, forKey: .energyMode) ?? defaults.energyMode,
            memoryProfile: try container.decodeIfPresent(ConjetMemoryProfile.self, forKey: .memoryProfile) ?? defaults.memoryProfile,
            ssh: try container.decodeIfPresent(ConjetSSHPolicy.self, forKey: .ssh) ?? defaults.ssh
        )
    }

    public var memoryPolicy: ConjetMemoryPolicy {
        let policyMemoryMiB = effectiveMemoryMiB
        let reclaimTarget = ConjetMemoryPolicy.defaultIdleMemoryReclaimTargetMiB(
            profile: memoryProfile,
            configuredMemoryMiB: policyMemoryMiB
        )
        return ConjetMemoryPolicy(
            profile: memoryProfile,
            configuredMemoryMiB: policyMemoryMiB,
            recommendedMemoryMiB: policyMemoryMiB,
            lazyRuntimeServices: false,
            lazyNetworkHelpers: true,
            reclaimIdleHelpersAfterSeconds: 0,
            idleWakeupBudgetPerSecond: 1.0,
            automaticIdleMemoryReclaim: ConjetMemoryPolicy.defaultAutomaticIdleMemoryReclaim(
                profile: memoryProfile,
                configuredMemoryMiB: policyMemoryMiB,
                targetMemoryMiB: reclaimTarget
            ),
            idleMemoryReclaimTargetMiB: reclaimTarget,
            idleMemoryReclaimDwellSeconds: ConjetMemoryPolicy.defaultIdleMemoryReclaimDwellSeconds(profile: memoryProfile),
            dynamicMemoryEnabled: ConjetMemoryPolicy.defaultDynamicMemoryEnabled(profile: memoryProfile),
            dynamicMemoryMinimumMiB: ConjetMemoryPolicy.defaultDynamicMemoryMinimumMiB(
                profile: memoryProfile,
                configuredMemoryMiB: policyMemoryMiB
            ),
            dynamicMemoryBaseOverheadMiB: ConjetMemoryPolicy.defaultDynamicMemoryBaseOverheadMiB(
                profile: memoryProfile,
                configuredMemoryMiB: policyMemoryMiB
            ),
            dynamicMemoryHeadroomMiB: ConjetMemoryPolicy.defaultDynamicMemoryHeadroomMiB(
                profile: memoryProfile,
                configuredMemoryMiB: policyMemoryMiB
            ),
            dynamicMemoryHeadroomRatio: ConjetMemoryPolicy.defaultDynamicMemoryHeadroomRatio(profile: memoryProfile),
            dynamicMemoryCacheAllowanceMiB: ConjetMemoryPolicy.defaultDynamicMemoryCacheAllowanceMiB(
                profile: memoryProfile,
                configuredMemoryMiB: policyMemoryMiB
            ),
            dynamicMemoryShrinkCooldownSeconds: ConjetMemoryPolicy.defaultDynamicMemoryShrinkCooldownSeconds(
                profile: memoryProfile,
                configuredMemoryMiB: policyMemoryMiB
            ),
            dynamicMemoryShrinkStepMiB: ConjetMemoryPolicy.defaultDynamicMemoryShrinkStepMiB(
                profile: memoryProfile,
                configuredMemoryMiB: policyMemoryMiB
            )
        )
    }

    public var effectiveVMCPUs: Int {
        switch vmProfile {
        case .dockerCompatibility:
            return vmCPUs
        case .pulseFast:
            return 1
        }
    }

    public var effectiveMemoryMiB: Int {
        switch vmProfile {
        case .dockerCompatibility:
            return memoryMiB
        case .pulseFast:
            return 512
        }
    }

    public var shouldAdvertiseBalloonDevice: Bool {
        vmProfile != .pulseFast
    }

    public static func loadOrCreate(paths: ConjetPaths = .default()) throws -> ConjetConfig {
        do {
            try paths.ensureBaseDirectories()
        } catch {
            throw configurationAccessError(path: paths.home, operation: "prepare Conjet home", underlying: error)
        }
        let manager = FileManager.default
        if manager.fileExists(atPath: paths.config.path) {
            let text: String
            do {
                text = try String(contentsOf: paths.config, encoding: .utf8)
            } catch {
                throw configurationAccessError(path: paths.config, operation: "read Conjet config", underlying: error)
            }
            return try parseTOML(text)
        }
        let config = ConjetConfig.default
        do {
            try config.renderTOML().write(to: paths.config, atomically: true, encoding: .utf8)
        } catch {
            throw configurationAccessError(path: paths.config, operation: "write Conjet config", underlying: error)
        }
        return config
    }

    public func save(paths: ConjetPaths = .default()) throws {
        do {
            try paths.ensureBaseDirectories()
            try renderTOML().write(to: paths.config, atomically: true, encoding: .utf8)
        } catch {
            throw ConjetConfig.configurationAccessError(path: paths.config, operation: "write Conjet config", underlying: error)
        }
    }

    private static func configurationAccessError(path: URL, operation: String, underlying: Error) -> ConjetError {
        var detail = underlying.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        while detail.last == "." {
            detail.removeLast()
        }
        var message = "could not \(operation) at \(path.path): \(detail)"
        if pathIsOnMountedVolume(path) {
            message += ". CONJET_HOME is on a mounted volume; grant Removable Volumes or Full Disk Access to the terminal app and Conjet.app in System Settings > Privacy & Security, or move CONJET_HOME to a local path."
        }
        return .filesystem(message)
    }

    private static func pathIsOnMountedVolume(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path == "/Volumes" || path.hasPrefix("/Volumes/")
    }

    public func renderTOML() -> String {
        var lines = [
            "# Conjet local configuration",
            "# This file is intentionally small until the VM and sync engines are stable.",
            "",
            "[daemon]",
            "quiet_stop_minutes = \(quietStopMinutes)",
            "energy_mode = \"\(energyMode.rawValue)\""
        ]
        if let socketPath {
            lines.append("socket_path = \"\(escapeTOML(socketPath))\"")
        }
        lines.append("")
        lines.append("[vm]")
        lines.append("profile = \"\(vmProfile.rawValue)\"")
        lines.append("cpus = \(vmCPUs)")
        lines.append("memory_mib = \(memoryMiB)")
        lines.append("memory_profile = \"\(memoryProfile.rawValue)\"")
        lines.append("architecture = \"\(escapeTOML(architecture))\"")
        lines.append("disk_gib = \(diskGiB)")
        if let diskImagePath {
            lines.append("disk_image_path = \"\(escapeTOML(diskImagePath))\"")
        }
        if let kernelImagePath {
            lines.append("kernel_image_path = \"\(escapeTOML(kernelImagePath))\"")
        }
        lines.append("runtime = \"\(escapeTOML(runtime))\"")
        lines.append("backend = \"\(vmBackend.rawValue)\"")
        lines.append("enable_rosetta = \(enableRosetta)")
        lines.append("enable_host_mounts = \(enableHostMounts)")
        lines.append("enable_removable_host_mounts = \(enableRemovableHostMounts)")
        lines.append("")
        lines.append("[images]")
        lines.append("conjet_core_repository = \"\(escapeTOML(conjetCoreRepository))\"")
        lines.append("")
        lines.append("[network]")
        lines.append("bind_policy = \"\(networkBindPolicy.rawValue)\"")
        lines.append("proxy_engine = \"\(networkProxyEngine.rawValue)\"")
        lines.append("bridge_engine = \"\(networkBridgeEngine.rawValue)\"")
        if !networkLANAllowedCIDRs.isEmpty {
            lines.append("lan_allowed_cidrs = \"\(escapeTOML(networkLANAllowedCIDRs.joined(separator: ",")))\"")
        }
        if !networkLANAllowedPorts.isEmpty {
            lines.append("lan_allowed_ports = \"\(networkLANAllowedPorts.map(String.init).joined(separator: ","))\"")
        }
        lines.append("")
        lines.append("[ssh]")
        lines.append("enabled = \(ssh.enabled)")
        lines.append("transport = \"\(escapeTOML(ssh.transport))\"")
        lines.append("allow_tcp_fallback = \(ssh.allowTCPFallback)")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    public static func parseTOML(_ text: String) throws -> ConjetConfig {
        var config = ConjetConfig.default
        var section = ""

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                continue
            }

            let parts = line.split(separator: "=", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2 else {
                throw ConjetError.decoding("invalid config line: \(line)")
            }

            let key = section.isEmpty ? parts[0] : "\(section).\(parts[0])"
            let value = parts[1]
            switch key {
            case "vm.cpus":
                config.vmCPUs = try parseInt(value, key: key)
            case "vm.memory_mib":
                config.memoryMiB = try parseInt(value, key: key)
            case "vm.profile":
                let parsed = parseString(value)
                guard let profile = ConjetVMProfile.parse(parsed) else {
                    throw ConjetError.decoding("vm.profile must be \(ConjetVMProfile.allowedValuesDescription)")
                }
                config.vmProfile = profile
            case "vm.memory_profile":
                let parsed = parseString(value)
                guard let profile = ConjetMemoryProfile.parse(parsed) else {
                    throw ConjetError.decoding("vm.memory_profile must be \(ConjetMemoryProfile.allowedValuesDescription)")
                }
                config.memoryProfile = profile
            case "vm.architecture":
                config.architecture = parseString(value)
            case "vm.disk_gib":
                config.diskGiB = try parseInt(value, key: key)
            case "vm.disk_image_path":
                let parsed = parseString(value)
                config.diskImagePath = parsed.isEmpty ? nil : parsed
            case "vm.kernel_image_path":
                let parsed = parseString(value)
                config.kernelImagePath = parsed.isEmpty ? nil : parsed
            case "vm.runtime":
                let parsed = parseString(value)
                guard let runtime = ConjetContainerRuntimeKind.parse(parsed) else {
                    throw ConjetError.decoding("vm.runtime must be \(ConjetContainerRuntimeKind.allowedValuesDescription)")
                }
                config.runtime = runtime.rawValue
            case "vm.backend":
                let parsed = parseString(value)
                guard let backend = ConjetVMBackend.parse(parsed) else {
                    throw ConjetError.decoding("vm.backend must be \(ConjetVMBackend.allowedValuesDescription)")
                }
                config.vmBackend = backend
            case "vm.enable_rosetta":
                config.enableRosetta = try parseBool(value, key: key)
            case "vm.enable_host_mounts":
                config.enableHostMounts = try parseBool(value, key: key)
            case "vm.enable_removable_host_mounts":
                config.enableRemovableHostMounts = try parseBool(value, key: key)
            case "daemon.quiet_stop_minutes":
                config.quietStopMinutes = try parseInt(value, key: key)
            case "daemon.energy_mode":
                let parsed = parseString(value)
                guard let mode = ConjetEnergyMode(rawValue: parsed) else {
                    throw ConjetError.decoding("daemon.energy_mode must be performance, balanced, or eco")
                }
                config.energyMode = mode
            case "daemon.socket_path":
                config.socketPath = parseString(value)
            case "images.conjet_core_repository":
                config.conjetCoreRepository = parseString(value)
            case "network.bind_policy":
                let parsed = parseString(value)
                guard let policy = ConjetNetworkBindPolicy(rawValue: parsed) else {
                    throw ConjetError.decoding("network.bind_policy must be secure-local, docker-strict, or lan-allowlist")
                }
                config.networkBindPolicy = policy
            case "network.proxy_engine":
                let parsed = parseString(value)
                let engine: ConjetNetworkProxyEngine
                if let parsedEngine = ConjetNetworkProxyEngine(rawValue: parsed) {
                    engine = parsedEngine
                } else {
                    switch parsed {
                    case "nio":
                        engine = .eventLoop
                    case "gcd-evented":
                        engine = .gcdFallback
                    default:
                        throw ConjetError.decoding("network.proxy_engine must be auto, nio, event-loop, gcd-evented, gcd-fallback, or turbo")
                    }
                }
                config.networkProxyEngine = engine
            case "network.bridge_engine":
                let parsed = parseString(value)
                let engine: ConjetNetworkBridgeEngine
                switch parsed {
                case "auto":
                    engine = .auto
                case "python", "python-legacy":
                    engine = .pythonLegacy
                case "conjet-netd", "conjet-netd-c":
                    engine = .conjetNetdC
                default:
                    throw ConjetError.decoding("network.bridge_engine must be auto, python-legacy, or conjet-netd-c")
                }
                config.networkBridgeEngine = engine
            case "network.lan_allowed_cidrs":
                config.networkLANAllowedCIDRs = parseCSVString(value)
            case "network.lan_allowed_ports":
                config.networkLANAllowedPorts = try parseCSVString(value).map {
                    guard let port = Int($0), port > 0, port <= 65_535 else {
                        throw ConjetError.decoding("network.lan_allowed_ports must contain TCP/UDP port numbers")
                    }
                    return port
                }
            case "ssh.enabled":
                config.ssh.enabled = try parseBool(value, key: key)
            case "ssh.transport":
                let parsed = parseString(value)
                guard ["proxy-command", "tcp"].contains(parsed) else {
                    throw ConjetError.decoding("ssh.transport must be proxy-command or tcp")
                }
                config.ssh.transport = parsed
            case "ssh.allow_tcp_fallback":
                config.ssh.allowTCPFallback = try parseBool(value, key: key)
            default:
                continue
            }
        }

        guard config.vmCPUs > 0 else {
            throw ConjetError.decoding("vm.cpus must be positive")
        }
        guard config.memoryMiB >= 512 else {
            throw ConjetError.decoding("vm.memory_mib must be at least 512")
        }
        guard ["aarch64", "x86_64"].contains(config.architecture) else {
            throw ConjetError.decoding("vm.architecture must be aarch64 or x86_64")
        }
        guard config.diskGiB > 0 else {
            throw ConjetError.decoding("vm.disk_gib must be positive")
        }
        guard ConjetContainerRuntimeKind.parse(config.runtime) != nil else {
            throw ConjetError.decoding("vm.runtime must be \(ConjetContainerRuntimeKind.allowedValuesDescription)")
        }
        guard isValidGitHubRepository(config.conjetCoreRepository) else {
            throw ConjetError.decoding("images.conjet_core_repository must use OWNER/REPO format")
        }
        if config.networkBindPolicy == .lanAllowlist,
           (!config.networkLANAllowedPorts.isEmpty && config.networkLANAllowedCIDRs.isEmpty) {
            throw ConjetError.decoding("network.lan_allowed_cidrs is required when lan_allowed_ports is set")
        }
        return config
    }

    private static func parseInt(_ value: String, key: String) throws -> Int {
        guard let intValue = Int(value) else {
            throw ConjetError.decoding("\(key) must be an integer")
        }
        return intValue
    }

    public static func parseMemorySizeMiB(_ value: String, key: String = "memory") throws -> Int {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let multiplier: Int
        if text.hasSuffix("mib") {
            text.removeLast(3)
            multiplier = 1
        } else if text.hasSuffix("mb") {
            text.removeLast(2)
            multiplier = 1
        } else if text.hasSuffix("m") {
            text.removeLast()
            multiplier = 1
        } else if text.hasSuffix("gib") {
            text.removeLast(3)
            multiplier = 1024
        } else if text.hasSuffix("gb") {
            text.removeLast(2)
            multiplier = 1024
        } else if text.hasSuffix("g") {
            text.removeLast()
            multiplier = 1024
        } else {
            multiplier = 1
        }
        guard let units = Int(text), units > 0 else {
            throw ConjetError.invalidArgument("\(key) must be a memory size such as 4096M or 4G")
        }
        let multiplied = units.multipliedReportingOverflow(by: multiplier)
        guard !multiplied.overflow else {
            throw ConjetError.invalidArgument("\(key) is too large")
        }
        guard multiplied.partialValue >= 512 else {
            throw ConjetError.invalidArgument("\(key) must be at least 512 MiB")
        }
        return multiplied.partialValue
    }

    private static func parseBool(_ value: String, key: String) throws -> Bool {
        switch value.lowercased() {
        case "true": return true
        case "false": return false
        default: throw ConjetError.decoding("\(key) must be true or false")
        }
    }

    private static func parseString(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\""), text.hasSuffix("\"") {
            text.removeFirst()
            text.removeLast()
        }
        return text.replacingOccurrences(of: "\\\"", with: "\"")
    }

    private static func parseCSVString(_ value: String) -> [String] {
        parseString(value)
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func stripComment(_ line: String) -> String {
        var inString = false
        var escaped = false
        var result = ""
        for character in line {
            if escaped {
                result.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                result.append(character)
                escaped = true
                continue
            }
            if character == "\"" {
                inString.toggle()
                result.append(character)
                continue
            }
            if character == "#", !inString {
                break
            }
            result.append(character)
        }
        return result
    }

    private func escapeTOML(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func isValidGitHubRepository(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && !$0.contains(" ") }
    }
}

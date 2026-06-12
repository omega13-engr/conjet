import Foundation

public enum ConjetEnergyMode: String, Codable, CaseIterable, Sendable {
    case performance
    case balanced
    case eco
}

public enum ConjetMemoryProfile: String, Codable, CaseIterable, Sendable {
    case performance
    case balanced
    case eco
}

public struct ConjetMemoryPolicy: Codable, Equatable, Sendable {
    public var profile: ConjetMemoryProfile
    public var configuredMemoryMiB: Int
    public var recommendedMemoryMiB: Int
    public var lazyRuntimeServices: Bool
    public var lazyNetworkHelpers: Bool
    public var reclaimIdleHelpersAfterSeconds: Int
    public var idleWakeupBudgetPerSecond: Double

    public init(
        profile: ConjetMemoryProfile,
        configuredMemoryMiB: Int,
        recommendedMemoryMiB: Int,
        lazyRuntimeServices: Bool,
        lazyNetworkHelpers: Bool,
        reclaimIdleHelpersAfterSeconds: Int,
        idleWakeupBudgetPerSecond: Double
    ) {
        self.profile = profile
        self.configuredMemoryMiB = configuredMemoryMiB
        self.recommendedMemoryMiB = recommendedMemoryMiB
        self.lazyRuntimeServices = lazyRuntimeServices
        self.lazyNetworkHelpers = lazyNetworkHelpers
        self.reclaimIdleHelpersAfterSeconds = reclaimIdleHelpersAfterSeconds
        self.idleWakeupBudgetPerSecond = idleWakeupBudgetPerSecond
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
    public var architecture: String
    public var diskGiB: Int
    public var diskImagePath: String?
    public var runtime: String
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
        vmCPUs: Int = 4,
        memoryMiB: Int = 8192,
        architecture: String = "aarch64",
        diskGiB: Int = 100,
        diskImagePath: String? = nil,
        runtime: String = "docker",
        quietStopMinutes: Int = 30,
        enableRosetta: Bool = true,
        enableHostMounts: Bool = true,
        enableRemovableHostMounts: Bool = false,
        socketPath: String? = nil,
        conjetCoreRepository: String = ConjetCoreReleaseSource.defaultRepository,
        networkBindPolicy: ConjetNetworkBindPolicy = .secureLocal,
        networkProxyEngine: ConjetNetworkProxyEngine = .auto,
        networkBridgeEngine: ConjetNetworkBridgeEngine = .auto,
        networkLANAllowedCIDRs: [String] = [],
        networkLANAllowedPorts: [Int] = [],
        energyMode: ConjetEnergyMode = .balanced,
        memoryProfile: ConjetMemoryProfile = .balanced,
        ssh: ConjetSSHPolicy = ConjetSSHPolicy()
    ) {
        self.vmCPUs = vmCPUs
        self.memoryMiB = memoryMiB
        self.architecture = architecture
        self.diskGiB = diskGiB
        self.diskImagePath = diskImagePath
        self.runtime = runtime
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

    public static let `default` = ConjetConfig()

    private enum CodingKeys: String, CodingKey {
        case vmCPUs
        case memoryMiB
        case architecture
        case diskGiB
        case diskImagePath
        case runtime
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
        self.init(
            vmCPUs: try container.decodeIfPresent(Int.self, forKey: .vmCPUs) ?? defaults.vmCPUs,
            memoryMiB: try container.decodeIfPresent(Int.self, forKey: .memoryMiB) ?? defaults.memoryMiB,
            architecture: try container.decodeIfPresent(String.self, forKey: .architecture) ?? defaults.architecture,
            diskGiB: try container.decodeIfPresent(Int.self, forKey: .diskGiB) ?? defaults.diskGiB,
            diskImagePath: try container.decodeIfPresent(String.self, forKey: .diskImagePath) ?? defaults.diskImagePath,
            runtime: try container.decodeIfPresent(String.self, forKey: .runtime) ?? defaults.runtime,
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
        switch memoryProfile {
        case .performance:
            return ConjetMemoryPolicy(
                profile: memoryProfile,
                configuredMemoryMiB: memoryMiB,
                recommendedMemoryMiB: max(memoryMiB, 8192),
                lazyRuntimeServices: false,
                lazyNetworkHelpers: false,
                reclaimIdleHelpersAfterSeconds: 900,
                idleWakeupBudgetPerSecond: 2.0
            )
        case .balanced:
            return ConjetMemoryPolicy(
                profile: memoryProfile,
                configuredMemoryMiB: memoryMiB,
                recommendedMemoryMiB: memoryMiB,
                lazyRuntimeServices: false,
                lazyNetworkHelpers: true,
                reclaimIdleHelpersAfterSeconds: 300,
                idleWakeupBudgetPerSecond: 1.0
            )
        case .eco:
            return ConjetMemoryPolicy(
                profile: memoryProfile,
                configuredMemoryMiB: memoryMiB,
                recommendedMemoryMiB: min(memoryMiB, 4096),
                lazyRuntimeServices: true,
                lazyNetworkHelpers: true,
                reclaimIdleHelpersAfterSeconds: 60,
                idleWakeupBudgetPerSecond: 0.2
            )
        }
    }

    public static func loadOrCreate(paths: ConjetPaths = .default()) throws -> ConjetConfig {
        try paths.ensureBaseDirectories()
        let manager = FileManager.default
        if manager.fileExists(atPath: paths.config.path) {
            let text = try String(contentsOf: paths.config, encoding: .utf8)
            return try parseTOML(text)
        }
        let config = ConjetConfig.default
        try config.renderTOML().write(to: paths.config, atomically: true, encoding: .utf8)
        return config
    }

    public func save(paths: ConjetPaths = .default()) throws {
        try paths.ensureBaseDirectories()
        try renderTOML().write(to: paths.config, atomically: true, encoding: .utf8)
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
        lines.append("cpus = \(vmCPUs)")
        lines.append("memory_mib = \(memoryMiB)")
        lines.append("memory_profile = \"\(memoryProfile.rawValue)\"")
        lines.append("architecture = \"\(escapeTOML(architecture))\"")
        lines.append("disk_gib = \(diskGiB)")
        if let diskImagePath {
            lines.append("disk_image_path = \"\(escapeTOML(diskImagePath))\"")
        }
        lines.append("runtime = \"\(escapeTOML(runtime))\"")
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
            case "vm.memory_profile":
                let parsed = parseString(value)
                guard let profile = ConjetMemoryProfile(rawValue: parsed) else {
                    throw ConjetError.decoding("vm.memory_profile must be performance, balanced, or eco")
                }
                config.memoryProfile = profile
            case "vm.architecture":
                config.architecture = parseString(value)
            case "vm.disk_gib":
                config.diskGiB = try parseInt(value, key: key)
            case "vm.disk_image_path":
                let parsed = parseString(value)
                config.diskImagePath = parsed.isEmpty ? nil : parsed
            case "vm.runtime":
                config.runtime = parseString(value)
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
        guard config.runtime == "docker" else {
            throw ConjetError.decoding("vm.runtime currently supports docker")
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

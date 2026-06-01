import Foundation

public enum ConjetNetworkBindPolicy: String, Codable, Equatable, Sendable, CaseIterable {
    case secureLocal = "secure-local"
    case dockerStrict = "docker-strict"
    case lanAllowlist = "lan-allowlist"
}

public enum ConjetNetworkProxyEngine: String, Codable, Equatable, Sendable, CaseIterable {
    case auto
    case eventLoop = "event-loop"
    case gcdFallback = "gcd-fallback"
    case turbo
}

public enum ConjetNetworkBridgeEngine: String, Codable, Equatable, Sendable, CaseIterable {
    case auto
    case pythonLegacy = "python-legacy"
    case conjetNetdC = "conjet-netd-c"
}

public enum ConjetPortProtocol: String, Codable, Equatable, Sendable, CaseIterable {
    case tcp
    case udp
}

public enum ConjetPortForwardState: String, Codable, Equatable, Sendable {
    case pending
    case reserving
    case listening
    case failedConflict = "failed_conflict"
    case failedGuestCapability = "failed_guest_capability"
    case failedGuestUnreachable = "failed_guest_unreachable"
    case failedProtocolUnsupported = "failed_protocol_unsupported"
    case failedPolicyDenied = "failed_policy_denied"
    case stopped
    case stale
    case repairing
}

public struct ConjetNetworkCapabilities: Codable, Equatable, Sendable {
    public var version: Int
    public var tcpProxy: Bool
    public var udpProxy: Bool
    public var dockerEvents: Bool
    public var containerIPLookup: Bool
    public var portProbe: Bool
    public var proxyMetrics: Bool
    public var guestEcho: Bool
    public var guestMetrics: Bool
    public var binaryFrames: Bool
    public var udpBinaryFrames: Bool
    public var persistentVsock: Bool
    public var tcpBinaryFrames: Bool
    public var persistentTCPVsock: Bool
    public var tcpVsockPool: Bool
    public var bridgeEngine: String?

    private enum CodingKeys: String, CodingKey {
        case version
        case tcpProxy
        case udpProxy
        case dockerEvents
        case containerIPLookup
        case portProbe
        case proxyMetrics
        case guestEcho
        case guestMetrics
        case binaryFrames
        case udpBinaryFrames
        case persistentVsock
        case tcpBinaryFrames
        case persistentTCPVsock
        case tcpVsockPool
        case bridgeEngine
    }

    public init(
        version: Int = 1,
        tcpProxy: Bool = false,
        udpProxy: Bool = false,
        dockerEvents: Bool = false,
        containerIPLookup: Bool = false,
        portProbe: Bool = false,
        proxyMetrics: Bool = false,
        guestEcho: Bool = false,
        guestMetrics: Bool = false,
        binaryFrames: Bool = false,
        udpBinaryFrames: Bool = false,
        persistentVsock: Bool = false,
        tcpBinaryFrames: Bool = false,
        persistentTCPVsock: Bool = false,
        tcpVsockPool: Bool = false,
        bridgeEngine: String? = nil
    ) {
        self.version = version
        self.tcpProxy = tcpProxy
        self.udpProxy = udpProxy
        self.dockerEvents = dockerEvents
        self.containerIPLookup = containerIPLookup
        self.portProbe = portProbe
        self.proxyMetrics = proxyMetrics
        self.guestEcho = guestEcho
        self.guestMetrics = guestMetrics
        self.binaryFrames = binaryFrames
        self.udpBinaryFrames = udpBinaryFrames
        self.persistentVsock = persistentVsock
        self.tcpBinaryFrames = tcpBinaryFrames
        self.persistentTCPVsock = persistentTCPVsock
        self.tcpVsockPool = tcpVsockPool
        self.bridgeEngine = bridgeEngine
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.tcpProxy = try container.decodeIfPresent(Bool.self, forKey: .tcpProxy) ?? false
        self.udpProxy = try container.decodeIfPresent(Bool.self, forKey: .udpProxy) ?? false
        self.dockerEvents = try container.decodeIfPresent(Bool.self, forKey: .dockerEvents) ?? false
        self.containerIPLookup = try container.decodeIfPresent(Bool.self, forKey: .containerIPLookup) ?? false
        self.portProbe = try container.decodeIfPresent(Bool.self, forKey: .portProbe) ?? false
        self.proxyMetrics = try container.decodeIfPresent(Bool.self, forKey: .proxyMetrics) ?? false
        self.guestEcho = try container.decodeIfPresent(Bool.self, forKey: .guestEcho) ?? false
        self.guestMetrics = try container.decodeIfPresent(Bool.self, forKey: .guestMetrics) ?? false
        self.binaryFrames = try container.decodeIfPresent(Bool.self, forKey: .binaryFrames) ?? false
        self.udpBinaryFrames = try container.decodeIfPresent(Bool.self, forKey: .udpBinaryFrames) ?? false
        self.persistentVsock = try container.decodeIfPresent(Bool.self, forKey: .persistentVsock) ?? false
        self.tcpBinaryFrames = try container.decodeIfPresent(Bool.self, forKey: .tcpBinaryFrames) ?? false
        self.persistentTCPVsock = try container.decodeIfPresent(Bool.self, forKey: .persistentTCPVsock) ?? false
        self.tcpVsockPool = try container.decodeIfPresent(Bool.self, forKey: .tcpVsockPool) ?? false
        self.bridgeEngine = try container.decodeIfPresent(String.self, forKey: .bridgeEngine)
    }
}

public struct ConjetPublishedPortRequest: Codable, Equatable, Hashable, Sendable {
    public var hostIP: String?
    public var hostPort: Int
    public var containerPort: Int
    public var `protocol`: ConjetPortProtocol
    public var containerID: String?
    public var containerName: String?
    public var targetIP: String?

    public init(
        hostIP: String?,
        hostPort: Int,
        containerPort: Int,
        protocol: ConjetPortProtocol,
        containerID: String? = nil,
        containerName: String? = nil,
        targetIP: String? = nil
    ) {
        self.hostIP = hostIP
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.protocol = `protocol`
        self.containerID = containerID
        self.containerName = containerName
        self.targetIP = targetIP
    }
}

public struct ConjetPortPolicyDecision: Codable, Equatable, Sendable {
    public var allowed: Bool
    public var bindAddresses: [String]
    public var warning: String?
    public var deniedReason: String?

    public init(
        allowed: Bool,
        bindAddresses: [String] = [],
        warning: String? = nil,
        deniedReason: String? = nil
    ) {
        self.allowed = allowed
        self.bindAddresses = bindAddresses
        self.warning = warning
        self.deniedReason = deniedReason
    }
}

public struct ConjetPortPolicy: Equatable, Sendable {
    public var bindPolicy: ConjetNetworkBindPolicy
    public var lanAllowedCIDRs: [String]
    public var lanAllowedPorts: [Int]

    public init(
        bindPolicy: ConjetNetworkBindPolicy = .secureLocal,
        lanAllowedCIDRs: [String] = [],
        lanAllowedPorts: [Int] = []
    ) {
        self.bindPolicy = bindPolicy
        self.lanAllowedCIDRs = lanAllowedCIDRs
        self.lanAllowedPorts = lanAllowedPorts
    }

    public func evaluate(_ request: ConjetPublishedPortRequest) -> ConjetPortPolicyDecision {
        let hostIP = normalizeHostIP(request.hostIP)
        switch bindPolicy {
        case .secureLocal:
            if isWildcard(hostIP) {
                return ConjetPortPolicyDecision(
                    allowed: true,
                    bindAddresses: ["127.0.0.1", "::1"],
                    warning: "Docker requested all-interface publish; Conjet secure-local policy mapped it to loopback."
                )
            }
            if isIPv4Loopback(hostIP) {
                return ConjetPortPolicyDecision(allowed: true, bindAddresses: ["127.0.0.1"])
            }
            if isIPv6Loopback(hostIP) {
                return ConjetPortPolicyDecision(allowed: true, bindAddresses: ["::1"])
            }
            return ConjetPortPolicyDecision(
                allowed: false,
                deniedReason: "secure-local denies non-loopback bind address \(hostIP)"
            )
        case .dockerStrict:
            let binds: [String]
            if hostIP == "0.0.0.0" || hostIP.isEmpty {
                binds = ["0.0.0.0"]
            } else if hostIP == "::" {
                binds = ["::"]
            } else {
                binds = [hostIP]
            }
            let warning = binds.contains("0.0.0.0") || binds.contains("::")
                ? "Docker-strict publishing can be reachable from outside your Mac if firewall/network allows it."
                : nil
            return ConjetPortPolicyDecision(allowed: true, bindAddresses: binds, warning: warning)
        case .lanAllowlist:
            if isIPv4Loopback(hostIP) {
                return ConjetPortPolicyDecision(allowed: true, bindAddresses: ["127.0.0.1"])
            }
            if isIPv6Loopback(hostIP) {
                return ConjetPortPolicyDecision(allowed: true, bindAddresses: ["::1"])
            }
            guard lanAllowedPorts.contains(request.hostPort), !lanAllowedCIDRs.isEmpty else {
                return ConjetPortPolicyDecision(
                    allowed: false,
                    deniedReason: "lan-allowlist requires the port and at least one CIDR to be explicitly allowed"
                )
            }
            return ConjetPortPolicyDecision(
                allowed: true,
                bindAddresses: isIPv6Wildcard(hostIP) ? ["::"] : ["0.0.0.0"],
                warning: "LAN allowlist permits port \(request.hostPort); verify firewall rules for CIDRs \(lanAllowedCIDRs.joined(separator: ", "))."
            )
        }
    }

    private func normalizeHostIP(_ hostIP: String?) -> String {
        guard let hostIP, !hostIP.isEmpty else { return "0.0.0.0" }
        return hostIP == "localhost" ? "127.0.0.1" : hostIP
    }

    private func isWildcard(_ hostIP: String) -> Bool {
        hostIP.isEmpty || hostIP == "0.0.0.0" || hostIP == "::"
    }

    private func isIPv6Wildcard(_ hostIP: String) -> Bool {
        hostIP == "::"
    }

    private func isIPv4Loopback(_ hostIP: String) -> Bool {
        hostIP == "127.0.0.1" || hostIP.hasPrefix("127.")
    }

    private func isIPv6Loopback(_ hostIP: String) -> Bool {
        hostIP == "::1"
    }
}

public struct ConjetPortForwardStatus: Codable, Equatable, Sendable {
    public var hostIP: String
    public var hostPort: Int
    public var `protocol`: ConjetPortProtocol
    public var targetIP: String?
    public var targetPort: Int
    public var containerID: String?
    public var containerName: String?
    public var state: ConjetPortForwardState
    public var error: String?
    public var warning: String?
    public var policy: ConjetNetworkBindPolicy
    public var proxyEngine: String
    public var acceptedConnections: UInt64
    public var activeConnections: UInt64
    public var closedConnections: UInt64
    public var bytesIn: UInt64
    public var bytesOut: UInt64
    public var connectionErrors: UInt64
    public var udpPacketsIn: UInt64
    public var udpPacketsOut: UInt64
    public var udpBytesIn: UInt64
    public var udpBytesOut: UInt64
    public var udpDroppedPackets: UInt64
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        hostIP: String,
        hostPort: Int,
        protocol: ConjetPortProtocol,
        targetIP: String? = nil,
        targetPort: Int,
        containerID: String? = nil,
        containerName: String? = nil,
        state: ConjetPortForwardState,
        error: String? = nil,
        warning: String? = nil,
        policy: ConjetNetworkBindPolicy,
        proxyEngine: String,
        acceptedConnections: UInt64 = 0,
        activeConnections: UInt64 = 0,
        closedConnections: UInt64 = 0,
        bytesIn: UInt64 = 0,
        bytesOut: UInt64 = 0,
        connectionErrors: UInt64 = 0,
        udpPacketsIn: UInt64 = 0,
        udpPacketsOut: UInt64 = 0,
        udpBytesIn: UInt64 = 0,
        udpBytesOut: UInt64 = 0,
        udpDroppedPackets: UInt64 = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.hostIP = hostIP
        self.hostPort = hostPort
        self.protocol = `protocol`
        self.targetIP = targetIP
        self.targetPort = targetPort
        self.containerID = containerID
        self.containerName = containerName
        self.state = state
        self.error = error
        self.warning = warning
        self.policy = policy
        self.proxyEngine = proxyEngine
        self.acceptedConnections = acceptedConnections
        self.activeConnections = activeConnections
        self.closedConnections = closedConnections
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.connectionErrors = connectionErrors
        self.udpPacketsIn = udpPacketsIn
        self.udpPacketsOut = udpPacketsOut
        self.udpBytesIn = udpBytesIn
        self.udpBytesOut = udpBytesOut
        self.udpDroppedPackets = udpDroppedPackets
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ConjetNetworkStatus: Codable, Equatable, Sendable {
    public var bindPolicy: ConjetNetworkBindPolicy
    public var proxyEngine: String
    public var bridgeEngine: String
    public var tcpMode: String
    public var udpMode: String
    public var tcpBinaryFrames: Bool
    public var persistentTCPVsock: Bool
    public var tcpVsockPool: Bool
    public var pythonFallbackActive: Bool
    public var requestedBridgeEngine: String?
    public var fallbackReason: String?
    public var eventWatcherState: String
    public var eventWatcherLastEventAt: Date?
    public var eventWatcherReconnects: Int
    public var periodicReconcileIntervalSeconds: Double
    public var capabilities: ConjetNetworkCapabilities
    public var activeTCPForwards: Int
    public var activeUDPForwards: Int
    public var failedForwards: Int
    public var conflictCount: Int
    public var staleForwards: Int
    public var vmNetworkMode: String
    public var turboAvailable: Bool
    public var turboEnabled: Bool
    public var lastReconcileAt: Date?
    public var forwards: [ConjetPortForwardStatus]
    public var messages: [String]

    private enum CodingKeys: String, CodingKey {
        case bindPolicy
        case proxyEngine
        case bridgeEngine
        case tcpMode
        case udpMode
        case tcpBinaryFrames
        case persistentTCPVsock
        case tcpVsockPool
        case pythonFallbackActive
        case requestedBridgeEngine
        case fallbackReason
        case eventWatcherState
        case eventWatcherLastEventAt
        case eventWatcherReconnects
        case periodicReconcileIntervalSeconds
        case capabilities
        case activeTCPForwards
        case activeUDPForwards
        case failedForwards
        case conflictCount
        case staleForwards
        case vmNetworkMode
        case turboAvailable
        case turboEnabled
        case lastReconcileAt
        case forwards
        case messages
    }

    public init(
        bindPolicy: ConjetNetworkBindPolicy = .secureLocal,
        proxyEngine: String = "unavailable",
        bridgeEngine: String = "unknown",
        tcpMode: String = "legacy-tcp-proxy",
        udpMode: String = "legacy-udp-proxy",
        tcpBinaryFrames: Bool = false,
        persistentTCPVsock: Bool = false,
        tcpVsockPool: Bool = false,
        pythonFallbackActive: Bool = false,
        requestedBridgeEngine: String? = nil,
        fallbackReason: String? = nil,
        eventWatcherState: String = "stopped",
        eventWatcherLastEventAt: Date? = nil,
        eventWatcherReconnects: Int = 0,
        periodicReconcileIntervalSeconds: Double = 45,
        capabilities: ConjetNetworkCapabilities = ConjetNetworkCapabilities(),
        activeTCPForwards: Int = 0,
        activeUDPForwards: Int = 0,
        failedForwards: Int = 0,
        conflictCount: Int = 0,
        staleForwards: Int = 0,
        vmNetworkMode: String = "vz-nat",
        turboAvailable: Bool = false,
        turboEnabled: Bool = false,
        lastReconcileAt: Date? = nil,
        forwards: [ConjetPortForwardStatus] = [],
        messages: [String] = []
    ) {
        self.bindPolicy = bindPolicy
        self.proxyEngine = proxyEngine
        self.bridgeEngine = bridgeEngine
        self.tcpMode = tcpMode
        self.udpMode = udpMode
        self.tcpBinaryFrames = tcpBinaryFrames
        self.persistentTCPVsock = persistentTCPVsock
        self.tcpVsockPool = tcpVsockPool
        self.pythonFallbackActive = pythonFallbackActive
        self.requestedBridgeEngine = requestedBridgeEngine
        self.fallbackReason = fallbackReason
        self.eventWatcherState = eventWatcherState
        self.eventWatcherLastEventAt = eventWatcherLastEventAt
        self.eventWatcherReconnects = eventWatcherReconnects
        self.periodicReconcileIntervalSeconds = periodicReconcileIntervalSeconds
        self.capabilities = capabilities
        self.activeTCPForwards = activeTCPForwards
        self.activeUDPForwards = activeUDPForwards
        self.failedForwards = failedForwards
        self.conflictCount = conflictCount
        self.staleForwards = staleForwards
        self.vmNetworkMode = vmNetworkMode
        self.turboAvailable = turboAvailable
        self.turboEnabled = turboEnabled
        self.lastReconcileAt = lastReconcileAt
        self.forwards = forwards
        self.messages = messages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedCapabilities = try container.decodeIfPresent(ConjetNetworkCapabilities.self, forKey: .capabilities) ?? ConjetNetworkCapabilities()
        let decodedBridgeEngine = try container.decodeIfPresent(String.self, forKey: .bridgeEngine) ?? decodedCapabilities.bridgeEngine ?? "unknown"
        let decodedTCPBinaryFrames = try container.decodeIfPresent(Bool.self, forKey: .tcpBinaryFrames) ?? decodedCapabilities.tcpBinaryFrames
        let decodedPersistentTCPVsock = try container.decodeIfPresent(Bool.self, forKey: .persistentTCPVsock) ?? decodedCapabilities.persistentTCPVsock
        let decodedTCPVsockPool = try container.decodeIfPresent(Bool.self, forKey: .tcpVsockPool) ?? decodedCapabilities.tcpVsockPool
        let decodedPythonFallbackActive = try container.decodeIfPresent(Bool.self, forKey: .pythonFallbackActive)
            ?? (decodedBridgeEngine == ConjetNetworkBridgeEngine.pythonLegacy.rawValue)
        let defaultTCPMode = decodedTCPBinaryFrames && decodedPersistentTCPVsock && decodedTCPVsockPool
            ? "persistent-binary-tcp-pool"
            : "legacy-tcp-proxy"
        let defaultUDPMode = decodedCapabilities.binaryFrames && decodedCapabilities.udpBinaryFrames && decodedCapabilities.persistentVsock
            ? "persistent-binary-udp"
            : "legacy-udp-proxy"

        self.bindPolicy = try container.decodeIfPresent(ConjetNetworkBindPolicy.self, forKey: .bindPolicy) ?? .secureLocal
        self.proxyEngine = try container.decodeIfPresent(String.self, forKey: .proxyEngine) ?? "unavailable"
        self.bridgeEngine = decodedBridgeEngine
        self.tcpMode = try container.decodeIfPresent(String.self, forKey: .tcpMode) ?? defaultTCPMode
        self.udpMode = try container.decodeIfPresent(String.self, forKey: .udpMode) ?? defaultUDPMode
        self.tcpBinaryFrames = decodedTCPBinaryFrames
        self.persistentTCPVsock = decodedPersistentTCPVsock
        self.tcpVsockPool = decodedTCPVsockPool
        self.pythonFallbackActive = decodedPythonFallbackActive
        self.requestedBridgeEngine = try container.decodeIfPresent(String.self, forKey: .requestedBridgeEngine)
        self.fallbackReason = try container.decodeIfPresent(String.self, forKey: .fallbackReason)
        self.eventWatcherState = try container.decodeIfPresent(String.self, forKey: .eventWatcherState) ?? "stopped"
        self.eventWatcherLastEventAt = try container.decodeIfPresent(Date.self, forKey: .eventWatcherLastEventAt)
        self.eventWatcherReconnects = try container.decodeIfPresent(Int.self, forKey: .eventWatcherReconnects) ?? 0
        self.periodicReconcileIntervalSeconds = try container.decodeIfPresent(Double.self, forKey: .periodicReconcileIntervalSeconds) ?? 45
        self.capabilities = decodedCapabilities
        self.activeTCPForwards = try container.decodeIfPresent(Int.self, forKey: .activeTCPForwards) ?? 0
        self.activeUDPForwards = try container.decodeIfPresent(Int.self, forKey: .activeUDPForwards) ?? 0
        self.failedForwards = try container.decodeIfPresent(Int.self, forKey: .failedForwards) ?? 0
        self.conflictCount = try container.decodeIfPresent(Int.self, forKey: .conflictCount) ?? 0
        self.staleForwards = try container.decodeIfPresent(Int.self, forKey: .staleForwards) ?? 0
        self.vmNetworkMode = try container.decodeIfPresent(String.self, forKey: .vmNetworkMode) ?? "vz-nat"
        self.turboAvailable = try container.decodeIfPresent(Bool.self, forKey: .turboAvailable) ?? false
        self.turboEnabled = try container.decodeIfPresent(Bool.self, forKey: .turboEnabled) ?? false
        self.lastReconcileAt = try container.decodeIfPresent(Date.self, forKey: .lastReconcileAt)
        self.forwards = try container.decodeIfPresent([ConjetPortForwardStatus].self, forKey: .forwards) ?? []
        self.messages = try container.decodeIfPresent([String].self, forKey: .messages) ?? []
    }
}

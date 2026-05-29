import ConjetCore
import Foundation

public enum ThermalPressure: String, Codable, Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical
}

public struct ActivitySnapshot: Codable, Equatable, Sendable {
    public var vmRunning: Bool
    public var activeContainers: Int
    public var activeBuilds: Int
    public var activeShells: Int
    public var recentFileEvents: Int
    public var networkRequestsPerSecond: Double
    public var secondsSinceLastActivity: Double
    public var onBattery: Bool
    public var thermalPressure: ThermalPressure

    public init(
        vmRunning: Bool,
        activeContainers: Int = 0,
        activeBuilds: Int = 0,
        activeShells: Int = 0,
        recentFileEvents: Int = 0,
        networkRequestsPerSecond: Double = 0,
        secondsSinceLastActivity: Double = .infinity,
        onBattery: Bool = false,
        thermalPressure: ThermalPressure = .nominal
    ) {
        self.vmRunning = vmRunning
        self.activeContainers = activeContainers
        self.activeBuilds = activeBuilds
        self.activeShells = activeShells
        self.recentFileEvents = recentFileEvents
        self.networkRequestsPerSecond = networkRequestsPerSecond
        self.secondsSinceLastActivity = secondsSinceLastActivity
        self.onBattery = onBattery
        self.thermalPressure = thermalPressure
    }
}

public struct ResourcePolicy: Codable, Equatable, Sendable {
    public var state: RuntimeState
    public var maxVCPUs: Int
    public var eventBatchWindowMilliseconds: Int
    public var syncScanIntervalSeconds: Int
    public var allowPrefetch: Bool
    public var performanceBias: Bool
    public var allowIdleStop: Bool

    public init(
        state: RuntimeState,
        maxVCPUs: Int,
        eventBatchWindowMilliseconds: Int,
        syncScanIntervalSeconds: Int,
        allowPrefetch: Bool,
        performanceBias: Bool,
        allowIdleStop: Bool
    ) {
        self.state = state
        self.maxVCPUs = maxVCPUs
        self.eventBatchWindowMilliseconds = eventBatchWindowMilliseconds
        self.syncScanIntervalSeconds = syncScanIntervalSeconds
        self.allowPrefetch = allowPrefetch
        self.performanceBias = performanceBias
        self.allowIdleStop = allowIdleStop
    }
}

public struct EnergyGovernor: Sendable {
    public var configuredVCPUs: Int
    public var quietStopSeconds: Double

    public init(configuredVCPUs: Int = 4, quietStopSeconds: Double = 30 * 60) {
        self.configuredVCPUs = max(1, configuredVCPUs)
        self.quietStopSeconds = quietStopSeconds
    }

    public func classify(snapshot: ActivitySnapshot) -> RuntimeState {
        if !snapshot.vmRunning {
            return .cold
        }
        if snapshot.activeBuilds > 0 {
            return .build
        }
        if snapshot.activeShells > 0 || snapshot.recentFileEvents > 0 || snapshot.networkRequestsPerSecond >= 1 {
            return .interactive
        }
        if snapshot.activeContainers > 0 {
            return snapshot.secondsSinceLastActivity < 10 ? .cooldown : .devIdle
        }
        if snapshot.secondsSinceLastActivity >= quietStopSeconds {
            return .cold
        }
        return snapshot.secondsSinceLastActivity < 10 ? .cooldown : .warmIdle
    }

    public func policy(for state: RuntimeState, snapshot: ActivitySnapshot? = nil) -> ResourcePolicy {
        let constrained = snapshot.map { $0.onBattery || $0.thermalPressure == .serious || $0.thermalPressure == .critical } ?? false
        let maxCPU = constrained ? max(1, configuredVCPUs / 2) : configuredVCPUs

        switch state {
        case .cold:
            return ResourcePolicy(
                state: .cold,
                maxVCPUs: 0,
                eventBatchWindowMilliseconds: 250,
                syncScanIntervalSeconds: 0,
                allowPrefetch: false,
                performanceBias: false,
                allowIdleStop: true
            )
        case .warmIdle:
            return ResourcePolicy(
                state: .warmIdle,
                maxVCPUs: 1,
                eventBatchWindowMilliseconds: constrained ? 250 : 150,
                syncScanIntervalSeconds: constrained ? 300 : 120,
                allowPrefetch: false,
                performanceBias: false,
                allowIdleStop: true
            )
        case .devIdle:
            return ResourcePolicy(
                state: .devIdle,
                maxVCPUs: max(1, maxCPU / 2),
                eventBatchWindowMilliseconds: constrained ? 200 : 100,
                syncScanIntervalSeconds: constrained ? 120 : 60,
                allowPrefetch: false,
                performanceBias: false,
                allowIdleStop: false
            )
        case .interactive:
            return ResourcePolicy(
                state: .interactive,
                maxVCPUs: max(1, maxCPU),
                eventBatchWindowMilliseconds: constrained ? 75 : 25,
                syncScanIntervalSeconds: 15,
                allowPrefetch: !constrained,
                performanceBias: true,
                allowIdleStop: false
            )
        case .build:
            return ResourcePolicy(
                state: .build,
                maxVCPUs: max(1, maxCPU),
                eventBatchWindowMilliseconds: 25,
                syncScanIntervalSeconds: 10,
                allowPrefetch: !constrained,
                performanceBias: true,
                allowIdleStop: false
            )
        case .cooldown:
            return ResourcePolicy(
                state: .cooldown,
                maxVCPUs: max(1, maxCPU / 2),
                eventBatchWindowMilliseconds: constrained ? 150 : 75,
                syncScanIntervalSeconds: 30,
                allowPrefetch: false,
                performanceBias: false,
                allowIdleStop: false
            )
        case .stopping:
            return ResourcePolicy(
                state: .stopping,
                maxVCPUs: 1,
                eventBatchWindowMilliseconds: 250,
                syncScanIntervalSeconds: 0,
                allowPrefetch: false,
                performanceBias: false,
                allowIdleStop: true
            )
        }
    }
}

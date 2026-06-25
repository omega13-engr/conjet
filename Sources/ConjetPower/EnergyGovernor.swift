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
    public var energyMode: ConjetEnergyMode
    public var maxVCPUs: Int
    public var eventBatchWindowMilliseconds: Int
    public var syncScanIntervalSeconds: Int
    public var statusPersistenceMinIntervalMilliseconds: Int
    public var metricsPersistenceMinIntervalMilliseconds: Int
    public var networkReconcileIntervalSeconds: Int
    public var helperIdleDelayMilliseconds: Int
    public var allowPrefetch: Bool
    public var performanceBias: Bool
    public var allowIdleStop: Bool

    public init(
        state: RuntimeState,
        energyMode: ConjetEnergyMode = .balanced,
        maxVCPUs: Int,
        eventBatchWindowMilliseconds: Int,
        syncScanIntervalSeconds: Int,
        statusPersistenceMinIntervalMilliseconds: Int,
        metricsPersistenceMinIntervalMilliseconds: Int,
        networkReconcileIntervalSeconds: Int,
        helperIdleDelayMilliseconds: Int,
        allowPrefetch: Bool,
        performanceBias: Bool,
        allowIdleStop: Bool
    ) {
        self.state = state
        self.energyMode = energyMode
        self.maxVCPUs = maxVCPUs
        self.eventBatchWindowMilliseconds = eventBatchWindowMilliseconds
        self.syncScanIntervalSeconds = syncScanIntervalSeconds
        self.statusPersistenceMinIntervalMilliseconds = statusPersistenceMinIntervalMilliseconds
        self.metricsPersistenceMinIntervalMilliseconds = metricsPersistenceMinIntervalMilliseconds
        self.networkReconcileIntervalSeconds = networkReconcileIntervalSeconds
        self.helperIdleDelayMilliseconds = helperIdleDelayMilliseconds
        self.allowPrefetch = allowPrefetch
        self.performanceBias = performanceBias
        self.allowIdleStop = allowIdleStop
    }
}

public struct EnergyGovernor: Sendable {
    public var configuredVCPUs: Int
    public var quietStopSeconds: Double
    public var mode: ConjetEnergyMode

    public init(configuredVCPUs: Int = 4, quietStopSeconds: Double = 30 * 60, mode: ConjetEnergyMode = .balanced) {
        self.configuredVCPUs = max(1, configuredVCPUs)
        self.quietStopSeconds = quietStopSeconds
        self.mode = mode
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
        let modeConstrained = constrained || mode == .eco
        let cpuDivisor = mode == .eco ? 2 : 1
        let maxCPU = modeConstrained ? max(1, configuredVCPUs / max(2, cpuDivisor * 2)) : configuredVCPUs

        switch state {
        case .cold:
            return ResourcePolicy(
                state: .cold,
                energyMode: mode,
                maxVCPUs: 0,
                eventBatchWindowMilliseconds: timing(cold: 250, balanced: 500, eco: 1000),
                syncScanIntervalSeconds: 0,
                statusPersistenceMinIntervalMilliseconds: timing(cold: 250, balanced: 750, eco: 1500),
                metricsPersistenceMinIntervalMilliseconds: timing(cold: 500, balanced: 1500, eco: 3000),
                networkReconcileIntervalSeconds: timing(cold: 45, balanced: 90, eco: 180),
                helperIdleDelayMilliseconds: timing(cold: 25, balanced: 75, eco: 150),
                allowPrefetch: false,
                performanceBias: false,
                allowIdleStop: true
            )
        case .warmIdle:
            return ResourcePolicy(
                state: .warmIdle,
                energyMode: mode,
                maxVCPUs: 1,
                eventBatchWindowMilliseconds: constrained ? 300 : timing(cold: 150, balanced: 300, eco: 750),
                syncScanIntervalSeconds: constrained ? 300 : timing(cold: 120, balanced: 180, eco: 300),
                statusPersistenceMinIntervalMilliseconds: timing(cold: 250, balanced: 1000, eco: 2500),
                metricsPersistenceMinIntervalMilliseconds: timing(cold: 1000, balanced: 3000, eco: 6000),
                networkReconcileIntervalSeconds: timing(cold: 45, balanced: 120, eco: 240),
                helperIdleDelayMilliseconds: timing(cold: 25, balanced: 100, eco: 250),
                allowPrefetch: false,
                performanceBias: false,
                allowIdleStop: true
            )
        case .devIdle:
            return ResourcePolicy(
                state: .devIdle,
                energyMode: mode,
                maxVCPUs: max(1, maxCPU / 2),
                eventBatchWindowMilliseconds: constrained ? 250 : timing(cold: 100, balanced: 200, eco: 500),
                syncScanIntervalSeconds: constrained ? 120 : timing(cold: 60, balanced: 90, eco: 180),
                statusPersistenceMinIntervalMilliseconds: timing(cold: 200, balanced: 750, eco: 2000),
                metricsPersistenceMinIntervalMilliseconds: timing(cold: 750, balanced: 2500, eco: 5000),
                networkReconcileIntervalSeconds: timing(cold: 45, balanced: 90, eco: 180),
                helperIdleDelayMilliseconds: timing(cold: 25, balanced: 75, eco: 200),
                allowPrefetch: false,
                performanceBias: false,
                allowIdleStop: false
            )
        case .interactive:
            return ResourcePolicy(
                state: .interactive,
                energyMode: mode,
                maxVCPUs: max(1, maxCPU),
                eventBatchWindowMilliseconds: constrained ? 100 : timing(cold: 25, balanced: 50, eco: 125),
                syncScanIntervalSeconds: timing(cold: 15, balanced: 30, eco: 60),
                statusPersistenceMinIntervalMilliseconds: timing(cold: 100, balanced: 300, eco: 750),
                metricsPersistenceMinIntervalMilliseconds: timing(cold: 250, balanced: 1000, eco: 2500),
                networkReconcileIntervalSeconds: timing(cold: 30, balanced: 60, eco: 120),
                helperIdleDelayMilliseconds: timing(cold: 0, balanced: 25, eco: 100),
                allowPrefetch: !modeConstrained,
                performanceBias: mode == .performance,
                allowIdleStop: false
            )
        case .build:
            return ResourcePolicy(
                state: .build,
                energyMode: mode,
                maxVCPUs: max(1, maxCPU),
                eventBatchWindowMilliseconds: timing(cold: 25, balanced: 50, eco: 125),
                syncScanIntervalSeconds: timing(cold: 10, balanced: 30, eco: 60),
                statusPersistenceMinIntervalMilliseconds: timing(cold: 100, balanced: 300, eco: 750),
                metricsPersistenceMinIntervalMilliseconds: timing(cold: 250, balanced: 1000, eco: 2500),
                networkReconcileIntervalSeconds: timing(cold: 30, balanced: 60, eco: 120),
                helperIdleDelayMilliseconds: timing(cold: 0, balanced: 25, eco: 100),
                allowPrefetch: !modeConstrained,
                performanceBias: mode == .performance,
                allowIdleStop: false
            )
        case .cooldown:
            return ResourcePolicy(
                state: .cooldown,
                energyMode: mode,
                maxVCPUs: max(1, maxCPU / 2),
                eventBatchWindowMilliseconds: constrained ? 200 : timing(cold: 75, balanced: 150, eco: 400),
                syncScanIntervalSeconds: timing(cold: 30, balanced: 60, eco: 120),
                statusPersistenceMinIntervalMilliseconds: timing(cold: 200, balanced: 750, eco: 2000),
                metricsPersistenceMinIntervalMilliseconds: timing(cold: 750, balanced: 2500, eco: 5000),
                networkReconcileIntervalSeconds: timing(cold: 45, balanced: 90, eco: 180),
                helperIdleDelayMilliseconds: timing(cold: 25, balanced: 75, eco: 200),
                allowPrefetch: false,
                performanceBias: false,
                allowIdleStop: false
            )
        case .stopping:
            return ResourcePolicy(
                state: .stopping,
                energyMode: mode,
                maxVCPUs: 1,
                eventBatchWindowMilliseconds: timing(cold: 250, balanced: 500, eco: 1000),
                syncScanIntervalSeconds: 0,
                statusPersistenceMinIntervalMilliseconds: timing(cold: 250, balanced: 750, eco: 1500),
                metricsPersistenceMinIntervalMilliseconds: timing(cold: 500, balanced: 1500, eco: 3000),
                networkReconcileIntervalSeconds: timing(cold: 45, balanced: 120, eco: 240),
                helperIdleDelayMilliseconds: timing(cold: 25, balanced: 100, eco: 250),
                allowPrefetch: false,
                performanceBias: false,
                allowIdleStop: true
            )
        }
    }

    private func timing(cold performance: Int, balanced: Int, eco: Int) -> Int {
        switch mode {
        case .performance:
            return performance
        case .balanced:
            return balanced
        case .eco:
            return eco
        }
    }
}

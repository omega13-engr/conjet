import ConjetCore
import ConjetPower
import XCTest

final class EnergyGovernorTests: XCTestCase {
    func testColdWhenVMIsNotRunning() {
        let governor = EnergyGovernor(configuredVCPUs: 8)
        let snapshot = ActivitySnapshot(vmRunning: false)
        XCTAssertEqual(governor.classify(snapshot: snapshot), .cold)
        XCTAssertEqual(governor.policy(for: .cold).maxVCPUs, 0)
    }

    func testBuildIsPerformanceBiased() {
        let governor = EnergyGovernor(configuredVCPUs: 8, mode: .performance)
        let snapshot = ActivitySnapshot(vmRunning: true, activeBuilds: 1)
        let state = governor.classify(snapshot: snapshot)
        let policy = governor.policy(for: state, snapshot: snapshot)
        XCTAssertEqual(state, .build)
        XCTAssertTrue(policy.performanceBias)
        XCTAssertEqual(policy.eventBatchWindowMilliseconds, 25)
    }

    func testBatteryConstrainsInteractivePolicy() {
        let governor = EnergyGovernor(configuredVCPUs: 8)
        let snapshot = ActivitySnapshot(vmRunning: true, activeShells: 1, onBattery: true)
        let policy = governor.policy(for: .interactive, snapshot: snapshot)
        XCTAssertEqual(policy.maxVCPUs, 4)
        XCTAssertFalse(policy.allowIdleStop)
    }

    func testBalancedAndEcoReduceBackgroundCadence() {
        let performance = EnergyGovernor(configuredVCPUs: 8, mode: .performance)
            .policy(for: .warmIdle)
        let balanced = EnergyGovernor(configuredVCPUs: 8, mode: .balanced)
            .policy(for: .warmIdle)
        let eco = EnergyGovernor(configuredVCPUs: 8, mode: .eco)
            .policy(for: .warmIdle)

        XCTAssertLessThan(performance.statusPersistenceMinIntervalMilliseconds, balanced.statusPersistenceMinIntervalMilliseconds)
        XCTAssertLessThan(balanced.statusPersistenceMinIntervalMilliseconds, eco.statusPersistenceMinIntervalMilliseconds)
        XCTAssertLessThan(performance.metricsPersistenceMinIntervalMilliseconds, balanced.metricsPersistenceMinIntervalMilliseconds)
        XCTAssertLessThan(balanced.networkReconcileIntervalSeconds, eco.networkReconcileIntervalSeconds)
    }

    func testEcoConstrainsActiveCPUAndDisablesPrefetch() {
        let governor = EnergyGovernor(configuredVCPUs: 8, mode: .eco)
        let snapshot = ActivitySnapshot(vmRunning: true, activeBuilds: 1)
        let policy = governor.policy(for: .build, snapshot: snapshot)

        XCTAssertEqual(policy.energyMode, .eco)
        XCTAssertEqual(policy.maxVCPUs, 2)
        XCTAssertFalse(policy.allowPrefetch)
        XCTAssertFalse(policy.performanceBias)
    }
}

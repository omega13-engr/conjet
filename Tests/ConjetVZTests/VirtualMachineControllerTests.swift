import ConjetCore
@testable import ConjetVZ
import XCTest

final class VirtualMachineControllerTests: XCTestCase {
    func testControllerOmittedBackendDefaultsToHVF() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-vm-controller-backend-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ConjetPaths(home: root)
        try paths.ensureBaseDirectories()
        let store = VMImageStore(paths: paths)
        let controller = VirtualMachineController()

        let status = controller.status(store: store)
        XCTAssertEqual(status.backend, .hvfExperimental)

        let stopped = try controller.stop(store: store)
        XCTAssertEqual(stopped.backend, .hvfExperimental)
    }

    func testManagedHVFReadinessTimeoutDefaultsToFirstBootSafeWindow() {
        XCTAssertEqual(
            VirtualMachineController.managedHVFReadinessTimeoutSeconds(environment: [:]),
            600
        )
    }

    func testManagedHVFReadinessTimeoutCanBeOverriddenByEnvironment() {
        XCTAssertEqual(
            VirtualMachineController.managedHVFReadinessTimeoutSeconds(
                environment: ["CONJET_JETSTREAM_HVF_READINESS_TIMEOUT_SECONDS": "45"]
            ),
            45
        )
        XCTAssertEqual(
            VirtualMachineController.managedHVFReadinessTimeoutSeconds(
                environment: ["CONJET_HVF_READINESS_TIMEOUT_SECONDS": "75"]
            ),
            75
        )
    }

    func testManagedHVFReadinessTimeoutRejectsTooSmallOrInvalidOverrides() {
        XCTAssertEqual(
            VirtualMachineController.managedHVFReadinessTimeoutSeconds(
                environment: ["CONJET_JETSTREAM_HVF_READINESS_TIMEOUT_SECONDS": "20"]
            ),
            600
        )
        XCTAssertEqual(
            VirtualMachineController.managedHVFReadinessTimeoutSeconds(
                environment: ["CONJET_JETSTREAM_HVF_READINESS_TIMEOUT_SECONDS": "not-a-number"]
            ),
            600
        )
    }

    func testMemoryReclaimRunningStateIncludesManagedHVFRun() {
        XCTAssertTrue(
            VirtualMachineController.memoryReclaimVMIsRunning(
                hvfRunIsRunning: true,
                virtualizationState: nil
            )
        )
        XCTAssertTrue(
            VirtualMachineController.memoryReclaimVMIsRunning(
                hvfRunIsRunning: false,
                virtualizationState: .running
            )
        )
        XCTAssertFalse(
            VirtualMachineController.memoryReclaimVMIsRunning(
                hvfRunIsRunning: false,
                virtualizationState: .stopped
            )
        )
        XCTAssertFalse(
            VirtualMachineController.memoryReclaimVMIsRunning(
                hvfRunIsRunning: false,
                virtualizationState: nil
            )
        )
    }

    func testRustMemorySocketsUseDockerSiblingWhenPathFits() {
        let dockerSocketPath = "/tmp/conjet-short/run/docker.sock"

        XCTAssertEqual(
            VirtualMachineController.rustMemorySocketPath(dockerSocketPath: dockerSocketPath),
            "/tmp/conjet-short/run/memory.sock"
        )
        XCTAssertEqual(
            VirtualMachineController.rustMemoryControlSocketPath(dockerSocketPath: dockerSocketPath),
            "/tmp/conjet-short/run/rust-memory-control.sock"
        )
    }

    func testRustMemorySocketsFallbackWhenSiblingPathExceedsUnixSocketLimit() {
        let longProfile = String(repeating: "nested-profile-segment-", count: 8)
        let dockerSocketPath = "/Volumes/ExternalSSD/dev_workspace/tmp/\(longProfile)/run/docker.sock"
        let memorySocketPath = VirtualMachineController.rustMemorySocketPath(dockerSocketPath: dockerSocketPath)
        let controlSocketPath = VirtualMachineController.rustMemoryControlSocketPath(dockerSocketPath: dockerSocketPath)

        XCTAssertTrue(memorySocketPath.hasPrefix("/tmp/conjet-"))
        XCTAssertTrue(memorySocketPath.hasSuffix("/memory.sock"))
        XCTAssertTrue(memorySocketPath.utf8CString.count <= 104)
        XCTAssertTrue(controlSocketPath.hasPrefix("/tmp/conjet-"))
        XCTAssertTrue(controlSocketPath.hasSuffix("/rust-memory-control.sock"))
        XCTAssertTrue(controlSocketPath.utf8CString.count <= 104)
        XCTAssertEqual(
            URL(fileURLWithPath: memorySocketPath).deletingLastPathComponent().path,
            URL(fileURLWithPath: controlSocketPath).deletingLastPathComponent().path
        )
    }

    func testRustVMMToolOnlyRepairsLocalCargoJetstreamExecutables() {
        #if os(macOS)
        let root = URL(fileURLWithPath: "/tmp/conjet-source", isDirectory: true)

        XCTAssertTrue(ConjetCoreRustVMMTool.isLocalDebugJetstreamExecutableForSigning(
            root.appendingPathComponent("target/debug/jetstream"),
            repositoryRoot: root
        ))
        XCTAssertTrue(ConjetCoreRustVMMTool.isLocalDebugJetstreamExecutableForSigning(
            root.appendingPathComponent("target/release/jetstream"),
            repositoryRoot: root
        ))
        XCTAssertTrue(ConjetCoreRustVMMTool.isLocalDebugJetstreamExecutableForSigning(
            root.appendingPathComponent("jetstream/target/debug/jetstream"),
            repositoryRoot: root
        ))
        XCTAssertFalse(ConjetCoreRustVMMTool.isLocalDebugJetstreamExecutableForSigning(
            root.appendingPathComponent(".build/debug/conjetd"),
            repositoryRoot: root
        ))
        XCTAssertFalse(ConjetCoreRustVMMTool.isLocalDebugJetstreamExecutableForSigning(
            root.appendingPathComponent("dist/Conjet.app/Contents/Resources/ConjetTools/ConjetCoreVMM/Conjet Core"),
            repositoryRoot: root
        ))
        XCTAssertFalse(ConjetCoreRustVMMTool.isLocalDebugJetstreamExecutableForSigning(
            URL(fileURLWithPath: "/usr/local/bin/jetstream"),
            repositoryRoot: root
        ))
        #endif
    }

    func testDockerBridgeReadinessPolicySkipsHostProbeForLegacyAutoBridge() {
        let policy = GuestDockerBridgeReadinessPolicy.resolve(
            requested: .auto,
            capabilities: GuestBridgeCapabilities(version: 1)
        )

        XCTAssertFalse(policy.requiresDockerAPIProbe)
        XCTAssertFalse(policy.requiresGuestControlCapability)
        XCTAssertFalse(policy.requiresGuestControlMounts)
    }

    func testDockerBridgeReadinessPolicyKeepsRequestedConjetNetdCCompatibleWithLegacyGuest() {
        let policy = GuestDockerBridgeReadinessPolicy.resolve(
            requested: .conjetNetdC,
            capabilities: GuestBridgeCapabilities(version: 1)
        )

        XCTAssertFalse(policy.requiresDockerAPIProbe)
        XCTAssertFalse(policy.requiresGuestControlCapability)
        XCTAssertFalse(policy.requiresGuestControlMounts)
    }

    func testDockerBridgeReadinessPolicyRequiresHostProbeForRequestedConjetNetdCWithGuestControl() {
        let policy = GuestDockerBridgeReadinessPolicy.resolve(
            requested: .conjetNetdC,
            capabilities: GuestBridgeCapabilities(
                version: 6,
                guestControl: true,
                bridgeEngine: ConjetNetworkBridgeEngine.conjetNetdC.rawValue
            )
        )

        XCTAssertTrue(policy.requiresDockerAPIProbe)
        XCTAssertTrue(policy.requiresGuestControlCapability)
        XCTAssertTrue(policy.requiresGuestControlMounts)
    }

    func testDockerBridgeReadinessPolicySkipsHostProbeForAutoDetectedConjetNetdCWithoutGuestControl() {
        let policy = GuestDockerBridgeReadinessPolicy.resolve(
            requested: .auto,
            capabilities: GuestBridgeCapabilities(
                version: 5,
                bridgeEngine: ConjetNetworkBridgeEngine.conjetNetdC.rawValue
            )
        )

        XCTAssertFalse(policy.requiresDockerAPIProbe)
        XCTAssertFalse(policy.requiresGuestControlCapability)
        XCTAssertFalse(policy.requiresGuestControlMounts)
    }

    func testDockerBridgeReadinessPolicyRequiresHostProbeForGuestControlCapability() {
        let policy = GuestDockerBridgeReadinessPolicy.resolve(
            requested: .pythonLegacy,
            capabilities: GuestBridgeCapabilities(
                version: 6,
                guestControl: true
            )
        )

        XCTAssertTrue(policy.requiresDockerAPIProbe)
        XCTAssertFalse(policy.requiresGuestControlCapability)
        XCTAssertTrue(policy.requiresGuestControlMounts)
    }

    func testDynamicMemoryTelemetryProgressPolicyDoesNotRegressRunningState() {
        XCTAssertEqual(VMAsyncProgressPolicy.dynamicMemoryTelemetryState(current: .starting), .starting)
        XCTAssertEqual(VMAsyncProgressPolicy.dynamicMemoryTelemetryState(current: .running), .running)
        XCTAssertNil(VMAsyncProgressPolicy.dynamicMemoryTelemetryState(current: .stopped))
        XCTAssertNil(VMAsyncProgressPolicy.dynamicMemoryTelemetryState(current: .stopping))
        XCTAssertNil(VMAsyncProgressPolicy.dynamicMemoryTelemetryState(current: .error))
        XCTAssertNil(VMAsyncProgressPolicy.dynamicMemoryTelemetryState(current: .unconfigured))
    }
}

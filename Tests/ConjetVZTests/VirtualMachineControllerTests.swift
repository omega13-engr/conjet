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

    func testRustVMMRunCapturesFailedStartupDiagnosticAndStopsAfterExit() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-rust-vmm-run-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stdout = root.appendingPathComponent("jetstream.stdout.log").path
        let stderr = root.appendingPathComponent("jetstream.stderr.log").path
        let run = try ConjetCoreRustVMMRun(
            executable: "/bin/sh",
            arguments: ["-c", "echo 'Error: HVF VM creation failed' >&2; exit 7"],
            stdoutPath: stdout,
            stderrPath: stderr
        )

        try run.start()
        let deadline = Date().addingTimeInterval(5)
        while run.resultSnapshot() == nil && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        XCTAssertTrue(run.stop(timeoutSeconds: 5))
        let result = try XCTUnwrap(run.resultSnapshot())
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertTrue(result.message.contains("HVF VM creation failed"), result.message)
    }

}

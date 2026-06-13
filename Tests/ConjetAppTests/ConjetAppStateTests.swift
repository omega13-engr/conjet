@testable import ConjetApp
@testable import ConjetAppCore
import ConjetCore
import XCTest

final class ConjetAppStateTests: XCTestCase {
    @MainActor
    func testRunningSnapshotCompletesStartingCommandState() {
        XCTAssertEqual(
            ConjetAppState.resolvedVMState(command: .starting, snapshot: .running),
            .running
        )
        XCTAssertTrue(ConjetAppState.isCommandTransitionComplete(command: .starting, actual: .running))
    }

    @MainActor
    func testStartingCommandStillWinsOverOldStoppedSnapshot() {
        XCTAssertEqual(
            ConjetAppState.resolvedVMState(command: .starting, snapshot: .stopped),
            .starting
        )
        XCTAssertFalse(ConjetAppState.isCommandTransitionComplete(command: .starting, actual: .stopped))
    }

    @MainActor
    func testStoppedSnapshotCompletesStoppingCommandState() {
        XCTAssertEqual(
            ConjetAppState.resolvedVMState(command: .stopping, snapshot: .stopped),
            .stopped
        )
        XCTAssertTrue(ConjetAppState.isCommandTransitionComplete(command: .stopping, actual: .stopped))
    }

    @MainActor
    func testStoppingCommandStillWinsOverOldRunningSnapshot() {
        XCTAssertEqual(
            ConjetAppState.resolvedVMState(command: .stopping, snapshot: .running),
            .stopping
        )
        XCTAssertFalse(ConjetAppState.isCommandTransitionComplete(command: .stopping, actual: .running))
    }

    @MainActor
    func testDockerReachableSnapshotReportsDegradedRuntimeHealthInsteadOfOffline() {
        let snapshot = DashboardSnapshot(
            conjetTool: Self.tool,
            conjetdTool: Self.tool,
            dockerTool: Self.tool,
            dockerSocketPath: "/tmp/conjet-home/run/docker.sock",
            dockerSocketAvailable: true,
            dockerReachable: true,
            daemonResponse: DaemonResponse(
                ok: false,
                message: "conjetd pid 123 is running but not answering at /tmp/conjet-home/run/conjetd.sock"
            )
        )

        let health = ConjetAppState.runtimeHealth(command: nil, snapshot: snapshot)

        XCTAssertEqual(health.state, .degraded)
        XCTAssertEqual(health.value, "degraded")
        XCTAssertEqual(health.detail, "Docker socket reachable")
        XCTAssertTrue(health.subtitle?.contains("Docker is reachable") == true)
    }

    @MainActor
    func testDockerReachableSnapshotProvidesInferredRunningVMStatus() {
        let snapshot = DashboardSnapshot(
            conjetTool: Self.tool,
            conjetdTool: Self.tool,
            dockerTool: Self.tool,
            dockerSocketPath: "/tmp/conjet-home/run/docker.sock",
            dockerSocketAvailable: true,
            dockerReachable: true,
            daemonResponse: DaemonResponse(ok: false, message: "daemon unavailable")
        )

        let vm = ConjetAppState.vmStatus(command: nil, snapshot: snapshot)

        XCTAssertEqual(vm?.state, .running)
        XCTAssertEqual(vm?.dockerSocketPath, "/tmp/conjet-home/run/docker.sock")
        XCTAssertEqual(vm?.message, "Docker socket is reachable; daemon VM status is unavailable")
    }

    func testImageSelectionIDKeepsTagsWithSameDigestDistinct() {
        let stable = "sha256:abcdef"
        let alpine = DockerImage(
            id: stable,
            repository: "nginx",
            tag: "alpine",
            size: "92.6MB",
            createdAt: "",
            createdSince: ""
        )
        let pinned = DockerImage(
            id: stable,
            repository: "nginx",
            tag: "1.31-alpine",
            size: "92.6MB",
            createdAt: "",
            createdSince: ""
        )

        XCTAssertNotEqual(alpine.selectionID, pinned.selectionID)
        XCTAssertEqual(alpine.reference, "nginx:alpine")
        XCTAssertEqual(pinned.reference, "nginx:1.31-alpine")
    }

    private static let tool = ResolvedTool(executable: "/tmp/conjet-test-tool", source: "test")
}

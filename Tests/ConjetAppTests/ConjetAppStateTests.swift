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
            conjetCoreTool: Self.tool,
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
            conjetCoreTool: Self.tool,
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

    @MainActor
    func testRestartRuntimeAppliesStartedDaemonVMStatus() async {
        let paths = Self.temporaryConjetPaths()
        let executor = RecordingCommandExecutor { invocation in
            Self.processResult(for: invocation, paths: paths)
        }
        let service = ConjetManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path],
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            executor: executor
        )
        let app = ConjetAppState(service: service)

        await app.restartRuntime()

        let invocations = await executor.invocations
        XCTAssertTrue(invocations.contains { $0.arguments == ["restart", "--json"] })
        XCTAssertEqual(app.currentVMState, .running)
        XCTAssertEqual(app.displayedVMStatus?.dockerSocketPath, paths.dockerSocket.path)
        XCTAssertEqual(app.runtimeHealth.state, .online)
        XCTAssertEqual(app.runtimeHealth.detail, "pid 456")
    }

    @MainActor
    func testRuntimeAndVMCommandsUseBoundedTimeouts() async {
        let paths = Self.temporaryConjetPaths()
        let executor = RecordingCommandExecutor { invocation in
            Self.processResult(for: invocation, paths: paths)
        }
        let service = ConjetManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path],
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            executor: executor
        )
        let app = ConjetAppState(service: service)

        await app.startRuntime()
        await app.vm("start")
        await app.vm("stop")

        let invocations = await executor.invocations
        XCTAssertEqual(invocations.first { $0.arguments == ["start", "--json"] }?.timeoutSeconds, 300)
        XCTAssertEqual(invocations.first { $0.arguments == ["vm", "start", "--json"] }?.timeoutSeconds, 300)
        XCTAssertEqual(invocations.first { $0.arguments == ["vm", "stop", "--json"] }?.timeoutSeconds, 90)
    }

    @MainActor
    func testStopRuntimeUsesSharedManagementStopWithoutConjetSubprocess() async {
        let paths = Self.temporaryConjetPaths()
        let executor = RecordingCommandExecutor { invocation in
            Self.processResult(for: invocation, paths: paths)
        }
        let service = ConjetManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path],
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            executor: executor
        )
        let app = ConjetAppState(service: service)

        await app.stopRuntime()

        let invocations = await executor.invocations
        XCTAssertFalse(invocations.contains { $0.arguments == ["stop", "--json"] })
        XCTAssertEqual(app.commandLog.first?.label, "Stop Conjet")
        XCTAssertEqual(app.commandLog.first?.commandLine, "conjet stop --timeout 75 --json")
    }

    @MainActor
    func testStopForQuitUsesBoundedJsonStop() async {
        let paths = Self.temporaryConjetPaths()
        let executor = RecordingCommandExecutor { invocation in
            Self.processResult(for: invocation, paths: paths)
        }
        let service = ConjetManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path],
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            executor: executor
        )
        let app = ConjetAppState(service: service)

        await app.stopForQuit()

        let invocations = await executor.invocations
        XCTAssertFalse(invocations.contains { $0.arguments == ["stop", "--timeout", "10", "--json"] })
        XCTAssertNil(app.activeCommandLabel)
        XCTAssertEqual(app.commandLog.first?.label, "Quit Conjet")
        XCTAssertEqual(app.commandLog.first?.commandLine, "conjet stop --timeout 10 --json")
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

    @MainActor
    func testRefreshSelectsCurrentProfileContext() async throws {
        let root = Self.temporaryConjetPaths().rootHome
        let paths = ConjetPaths(home: root, profileName: "staging")
        try paths.ensureBaseDirectories()
        try FileManager.default.createDirectory(
            at: paths.rootHome
                .appendingPathComponent("profiles", isDirectory: true)
                .appendingPathComponent("dev", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }

        let executor = RecordingCommandExecutor { invocation in
            Self.processResult(for: invocation, paths: paths)
        }
        let service = ConjetManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path, "CONJET_PROFILE": paths.profileName],
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            includeLaunchdEnvironment: false,
            executor: executor
        )
        let app = ConjetAppState(service: service)

        await app.refresh()

        XCTAssertEqual(app.selectedProfileName, "staging")
        XCTAssertEqual(app.currentProfileContext?.name, "staging")
        XCTAssertEqual(app.currentProfileContext?.dockerSocketPath, paths.dockerSocket.path)
        XCTAssertEqual(app.snapshot.profileContexts.map(\.name), ["default", "dev", "staging"])
    }

    @MainActor
    func testAutomaticBackgroundRefreshSkipsDockerInventoryAndKeepsManualRefreshAvailable() async throws {
        let paths = Self.temporaryConjetPaths()
        try paths.ensureBaseDirectories()
        FileManager.default.createFile(atPath: paths.dockerSocket.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }

        let executor = RecordingCommandExecutor { invocation in
            Self.processResult(for: invocation, paths: paths)
        }
        let service = ConjetManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path],
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            includeLaunchdEnvironment: false,
            executor: executor
        )
        let app = ConjetAppState(service: service)
        let container = DockerContainer(
            id: "api",
            name: "api",
            image: "alpine:3.20",
            state: "running",
            status: "Up 2 minutes"
        )
        app.snapshot = DashboardSnapshot(
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            dockerSocketPath: paths.dockerSocket.path,
            dockerSocketAvailable: true,
            dockerReachable: true,
            profiles: ["default"],
            profileContexts: [ConjetProfileContext(paths: paths, isCurrent: true)],
            containers: [container],
            refreshStatus: .succeeded
        )

        await app.refreshAutomaticallyForTesting()

        let invocations = await executor.invocations
        XCTAssertFalse(app.isRefreshing)
        XCTAssertFalse(app.interactiveSurfaceVisible)
        XCTAssertEqual(app.snapshot.containers.map(\.name), ["api"])
        XCTAssertFalse(invocations.contains { $0.arguments.contains("ps") })
        XCTAssertFalse(invocations.contains { $0.arguments.contains("images") })
        XCTAssertFalse(invocations.contains { $0.arguments.contains("volume") && $0.arguments.contains("ls") })
        XCTAssertFalse(invocations.contains { $0.arguments.contains("stats") })
        XCTAssertFalse(invocations.contains { $0.arguments.contains("top") })
    }

    @MainActor
    func testPulseHeartbeatUpdatesConnectionWithoutSchedulingRefresh() async throws {
        let paths = Self.temporaryConjetPaths()
        let executor = RecordingCommandExecutor { invocation in
            Self.processResult(for: invocation, paths: paths)
        }
        let service = ConjetManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path],
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            includeLaunchdEnvironment: false,
            executor: executor
        )
        let app = ConjetAppState(service: service)

        app.applyPulseFrameForTesting(.heartbeat(state: ConjetPulseState(highWatermark: 7, replayAvailableFrom: 1)))
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertTrue(app.pulseConnected)
        XCTAssertEqual(app.pulseHighWatermark, 7)
        let invocations = await executor.invocations
        XCTAssertTrue(invocations.isEmpty)
    }

    @MainActor
    func testPulseLifecycleEventSchedulesBackgroundStatusOnlyRefresh() async throws {
        let paths = Self.temporaryConjetPaths()
        try paths.ensureBaseDirectories()
        FileManager.default.createFile(atPath: paths.dockerSocket.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }

        let executor = RecordingCommandExecutor { invocation in
            Self.processResult(for: invocation, paths: paths)
        }
        let service = ConjetManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path],
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            includeLaunchdEnvironment: false,
            executor: executor
        )
        let app = ConjetAppState(service: service)
        app.snapshot = DashboardSnapshot(
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            dockerSocketPath: paths.dockerSocket.path,
            dockerSocketAvailable: true,
            dockerReachable: true,
            containers: [
                DockerContainer(
                    id: "api",
                    name: "api",
                    image: "alpine:3.20",
                    state: "running",
                    status: "Up 2 minutes"
                )
            ],
            refreshStatus: .succeeded
        )
        let event = ConjetPulseEvent(
            seq: 4,
            type: .vmStarted,
            subjectID: "vm",
            message: "running"
        )

        app.applyPulseFrameForTesting(ConjetPulseFrame(
            kind: .events,
            state: ConjetPulseState(highWatermark: 4, replayAvailableFrom: 1),
            events: [event]
        ))
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(app.pulseConnected)
        XCTAssertEqual(app.pulseHighWatermark, 4)
        XCTAssertEqual(app.snapshot.containers.map(\.name), ["api"])
        let invocations = await executor.invocations
        XCTAssertFalse(invocations.contains { $0.arguments.contains("ps") })
        XCTAssertFalse(invocations.contains { $0.arguments.contains("images") })
        XCTAssertFalse(invocations.contains { $0.arguments.contains("volume") && $0.arguments.contains("ls") })
        XCTAssertFalse(invocations.contains { $0.arguments.contains("stats") })
        XCTAssertFalse(invocations.contains { $0.arguments.contains("top") })
    }

    @MainActor
    func testPulseConnectedForegroundVolumeRefreshLoadsVisibleResourceInventory() async throws {
        let paths = Self.temporaryConjetPaths()
        try paths.ensureBaseDirectories()
        FileManager.default.createFile(atPath: paths.dockerSocket.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }

        let executor = RecordingCommandExecutor { invocation in
            Self.processResult(for: invocation, paths: paths)
        }
        let service = ConjetManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path],
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            includeLaunchdEnvironment: false,
            executor: executor
        )
        let app = ConjetAppState(service: service)
        app.selectedSection = .volumes
        app.snapshot = DashboardSnapshot(
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            dockerSocketPath: paths.dockerSocket.path,
            dockerSocketAvailable: true,
            dockerReachable: true,
            volumes: [
                DockerVolume(
                    name: "api-data",
                    driver: "local",
                    scope: "local",
                    mountpoint: "/var/lib/docker/volumes/api-data/_data",
                    labels: ""
                )
            ],
            refreshStatus: .succeeded
        )
        app.setInteractiveSurfaceVisible(true)
        app.applyPulseFrameForTesting(.heartbeat(state: ConjetPulseState(highWatermark: 9, replayAvailableFrom: 1)))

        try await Task.sleep(nanoseconds: 200_000_000)
        await app.refreshAutomaticallyForTesting()

        let invocations = await executor.invocations
        XCTAssertTrue(app.pulseConnected)
        XCTAssertFalse(invocations.contains { $0.arguments.contains("ps") })
        XCTAssertFalse(invocations.contains { $0.arguments.contains("images") })
        XCTAssertTrue(invocations.contains { $0.arguments.contains("volume") && $0.arguments.contains("ls") })
        XCTAssertTrue(invocations.contains { $0.arguments.contains("system") && $0.arguments.contains("df") })
        XCTAssertFalse(invocations.contains { $0.arguments.contains("stats") })
        XCTAssertFalse(invocations.contains { $0.arguments.contains("top") })
    }

    @MainActor
    func testPulseConnectedForegroundImageRefreshLoadsWhenSnapshotWasNeverLoaded() async throws {
        let paths = Self.temporaryConjetPaths()
        try paths.ensureBaseDirectories()
        FileManager.default.createFile(atPath: paths.dockerSocket.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }

        let executor = RecordingCommandExecutor { invocation in
            if invocation.arguments.contains("images") {
                return ProcessResult(
                    executable: invocation.executable,
                    arguments: invocation.arguments,
                    exitCode: 0,
                    stdout: """
                    {"ID":"sha256:ubuntu","Repository":"ubuntu","Tag":"24.04","Size":"101MB","CreatedAt":"2026-05-20 09:37:34 +0800 PST","CreatedSince":"5 weeks ago"}
                    """,
                    stderr: ""
                )
            }
            return Self.processResult(for: invocation, paths: paths)
        }
        let service = ConjetManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path],
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            includeLaunchdEnvironment: false,
            executor: executor
        )
        let app = ConjetAppState(service: service)
        app.selectedSection = .images
        app.setInteractiveSurfaceVisible(true)
        app.applyPulseFrameForTesting(.heartbeat(state: ConjetPulseState(highWatermark: 10, replayAvailableFrom: 1)))

        await app.refreshAutomaticallyForTesting()

        XCTAssertTrue(app.pulseConnected)
        XCTAssertEqual(app.snapshot.images.map(\.reference), ["ubuntu:24.04"])
        let invocations = await executor.invocations
        XCTAssertTrue(invocations.contains { $0.arguments.contains("images") })
        XCTAssertFalse(invocations.contains { $0.arguments.contains("ps") })
        XCTAssertFalse(invocations.contains { $0.arguments.contains("volume") && $0.arguments.contains("ls") })
    }

    @MainActor
    func testManualVolumeRefreshAlwaysRunsUsageProbe() async throws {
        let paths = Self.temporaryConjetPaths()
        try paths.ensureBaseDirectories()
        FileManager.default.createFile(atPath: paths.dockerSocket.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }

        let executor = RecordingCommandExecutor { invocation in
            Self.processResult(for: invocation, paths: paths)
        }
        let service = ConjetManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path],
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            includeLaunchdEnvironment: false,
            executor: executor
        )
        let app = ConjetAppState(service: service)
        app.selectedSection = .volumes

        await app.refresh()
        await app.refresh()

        let invocations = await executor.invocations
        let usageProbeCount = invocations.filter { $0.arguments.contains("system") && $0.arguments.contains("df") }.count
        XCTAssertEqual(usageProbeCount, 2)
        XCTAssertTrue(invocations.contains { $0.arguments.contains("volume") && $0.arguments.contains("ls") })
        XCTAssertFalse(invocations.contains { $0.arguments.contains("ps") })
        XCTAssertFalse(invocations.contains { $0.arguments.contains("images") })
        XCTAssertFalse(invocations.contains { $0.arguments.contains("stats") })
        XCTAssertFalse(invocations.contains { $0.arguments.contains("top") })
    }

    @MainActor
    func testVisibleTabLoadDoesNotRepeatWithoutEventsOrUserAction() async throws {
        let paths = Self.temporaryConjetPaths()
        try paths.ensureBaseDirectories()
        FileManager.default.createFile(atPath: paths.dockerSocket.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }

        let executor = RecordingCommandExecutor { invocation in
            Self.processResult(for: invocation, paths: paths)
        }
        let service = ConjetManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path],
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            includeLaunchdEnvironment: false,
            executor: executor
        )
        let app = ConjetAppState(service: service)
        app.selectedSection = .volumes
        app.setInteractiveSurfaceVisible(true)
        app.startAutoRefresh()

        try await Task.sleep(nanoseconds: 400_000_000)
        let settledInvocationCount = (await executor.invocations).count
        try await Task.sleep(nanoseconds: 900_000_000)
        let finalInvocationCount = (await executor.invocations).count

        XCTAssertEqual(finalInvocationCount, settledInvocationCount)
    }

    @MainActor
    func testPreservesKnownVolumeSizesAcrossCheapRefreshes() {
        let current = DashboardSnapshot(
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            dockerSocketPath: "/tmp/conjet-home/run/docker.sock",
            dockerSocketAvailable: true,
            dockerReachable: true,
            volumes: [
                DockerVolume(
                    name: "api-data",
                    driver: "local",
                    scope: "local",
                    mountpoint: "/var/lib/docker/volumes/api-data/_data",
                    labels: "",
                    size: "42MB"
                )
            ],
            refreshStatus: .succeeded
        )
        let latest = DashboardSnapshot(
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            dockerSocketPath: "/tmp/conjet-home/run/docker.sock",
            dockerSocketAvailable: true,
            dockerReachable: true,
            volumes: [
                DockerVolume(
                    name: "api-data",
                    driver: "local",
                    scope: "local",
                    mountpoint: "/var/lib/docker/volumes/api-data/_data",
                    labels: "",
                    size: "N/A"
                )
            ],
            refreshStatus: DashboardRefreshStatus(
                volumesSucceeded: true
            )
        )

        let merged = ConjetAppState.preservingPreviousResources(current: current, latest: latest)

        XCTAssertEqual(merged.volumes.first?.displaySize, "42MB")
    }

    @MainActor
    func testCreateAndUseProfileDoesNotStopExistingProfileRuntime() async throws {
        let paths = Self.temporaryConjetPaths()
        try paths.ensureBaseDirectories()
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }
        let persistedEnvironment = paths.rootHome.appendingPathComponent("runtime-environment.json")
        let executor = RecordingCommandExecutor { invocation in
            Self.processResult(for: invocation, paths: paths)
        }
        let service = ConjetManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path, "CONJET_PROFILE": "default"],
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            includeLaunchdEnvironment: false,
            persistedRuntimeEnvironmentURL: persistedEnvironment,
            executor: executor
        )
        let app = ConjetAppState(service: service)
        app.newProfileName = "staging"

        await app.createProfile(switchToNew: true)

        let stagingPaths = ConjetPaths(home: paths.rootHome, profileName: "staging")
        XCTAssertEqual(app.newProfileName, "")
        XCTAssertEqual(app.currentProfileContext?.name, "staging")
        XCTAssertEqual(app.selectedProfileName, "staging")
        XCTAssertEqual(app.snapshot.dockerSocketPath, stagingPaths.dockerSocket.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingPaths.config.path))
        XCTAssertTrue(app.profileActionMessage?.contains("Other profile VMs were left running") == true)
        XCTAssertNil(app.profileActionError)
        XCTAssertTrue(app.commandLog.first?.commandLine.contains("conjet profile create staging") == true)
        let invocations = await executor.invocations
        XCTAssertFalse(invocations.contains { $0.arguments.contains("stop") })
    }

    @MainActor
    func testProfileSwitchDoesNotPreserveOldProfileResourcesWhenNewProfileIsOffline() {
        let oldContainer = DockerContainer(
            id: "old",
            name: "old-profile-container",
            image: "alpine:3.20",
            state: "running",
            status: "Up"
        )
        let current = DashboardSnapshot(
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            dockerSocketPath: "/tmp/conjet-home/run/docker.sock",
            dockerSocketAvailable: true,
            dockerReachable: true,
            profiles: ["default", "staging"],
            profileContexts: [
                ConjetProfileContext(name: "default", isCurrent: true, dockerSocketPath: "/tmp/conjet-home/run/docker.sock"),
                ConjetProfileContext(name: "staging", dockerSocketPath: "/tmp/conjet-home/profiles/staging/run/docker.sock")
            ],
            containers: [oldContainer],
            refreshStatus: .succeeded
        )
        let latest = DashboardSnapshot(
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            dockerSocketPath: "/tmp/conjet-home/profiles/staging/run/docker.sock",
            dockerSocketAvailable: false,
            dockerReachable: false,
            profiles: ["default", "staging"],
            profileContexts: [
                ConjetProfileContext(name: "default", dockerSocketPath: "/tmp/conjet-home/run/docker.sock"),
                ConjetProfileContext(name: "staging", isCurrent: true, dockerSocketPath: "/tmp/conjet-home/profiles/staging/run/docker.sock")
            ],
            containers: [],
            refreshStatus: .none
        )

        let merged = ConjetAppState.preservingPreviousResources(current: current, latest: latest)

        XCTAssertEqual(merged.profileContexts.first(where: { $0.isCurrent })?.name, "staging")
        XCTAssertEqual(merged.containers, [])
        XCTAssertFalse(merged.dockerReachable)
    }

    @MainActor
    func testSaveProfileConfigPromptsForRestartWithoutRestarting() async throws {
        let paths = Self.temporaryConjetPaths()
        try paths.ensureBaseDirectories()
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }
        let executor = RecordingCommandExecutor { invocation in
            Self.processResult(for: invocation, paths: paths)
        }
        let service = ConjetManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path, "CONJET_PROFILE": "default"],
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            includeLaunchdEnvironment: false,
            executor: executor
        )
        let app = ConjetAppState(
            service: service,
            profileMemoryBounds: ConjetProfileMemoryBounds(hostMemoryMiB: 32_768)
        )
        let profile = ConjetProfileContext(paths: paths, isCurrent: true)

        app.loadProfileConfig(profile)
        app.profileConfigDraft?.vmCPUs = 6
        app.profileConfigDraft?.memoryMiB = 12_288
        app.profileConfigDraft?.networkBindPolicy = .lanAllowlist
        app.profileConfigDraft?.networkLANAllowedCIDRs = "192.168.10.0/24"
        app.profileConfigDraft?.networkLANAllowedPorts = "8080, 8443"

        await app.saveProfileConfig()
        let config = try ConjetConfig.loadOrCreate(paths: paths)

        XCTAssertEqual(config.vmCPUs, 6)
        XCTAssertEqual(config.memoryMiB, 12_288)
        XCTAssertEqual(config.networkBindPolicy, .lanAllowlist)
        XCTAssertEqual(config.networkLANAllowedCIDRs, ["192.168.10.0/24"])
        XCTAssertEqual(config.networkLANAllowedPorts, [8080, 8443])
        XCTAssertTrue(app.showProfileRestartPrompt)
        XCTAssertEqual(app.pendingRestartProfileName, "default")
        XCTAssertEqual(app.profileConfigMessage, "Saved profile default.")
        XCTAssertNil(app.profileConfigError)
        let invocations = await executor.invocations
        XCTAssertFalse(invocations.contains { $0.arguments.contains("restart") })
        XCTAssertFalse(invocations.contains { $0.arguments.contains("stop") })
    }

    @MainActor
    func testSaveProfileConfigClampsMemoryForSixteenGiBHost() async throws {
        let paths = Self.temporaryConjetPaths()
        try paths.ensureBaseDirectories()
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }
        let executor = RecordingCommandExecutor { invocation in
            Self.processResult(for: invocation, paths: paths)
        }
        let service = ConjetManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path, "CONJET_PROFILE": "default"],
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            includeLaunchdEnvironment: false,
            executor: executor
        )
        let app = ConjetAppState(
            service: service,
            profileMemoryBounds: ConjetProfileMemoryBounds(hostMemoryMiB: 16_384)
        )
        let profile = ConjetProfileContext(paths: paths, isCurrent: true)

        app.loadProfileConfig(profile)
        app.profileConfigDraft?.memoryMiB = 16_384

        await app.saveProfileConfig()
        let config = try ConjetConfig.loadOrCreate(paths: paths)

        XCTAssertEqual(config.memoryMiB, 8192)
        XCTAssertEqual(app.profileConfigDraft?.memoryMiB, 8192)
        XCTAssertNil(app.profileConfigError)
    }

    @MainActor
    func testRestartLaterKeepsSavedConfigWithoutRuntimeCommand() async throws {
        let paths = Self.temporaryConjetPaths()
        try paths.ensureBaseDirectories()
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }
        let executor = RecordingCommandExecutor { invocation in
            Self.processResult(for: invocation, paths: paths)
        }
        let service = ConjetManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path],
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            includeLaunchdEnvironment: false,
            executor: executor
        )
        let app = ConjetAppState(service: service)
        app.profileConfigDraft = ProfileConfigDraft(profileName: "default", config: .default)

        await app.saveProfileConfig()
        app.restartPendingProfileLater()

        XCTAssertFalse(app.showProfileRestartPrompt)
        XCTAssertNil(app.pendingRestartProfileName)
        XCTAssertEqual(app.profileConfigMessage, "Saved profile default.")
        let invocations = await executor.invocations
        XCTAssertFalse(invocations.contains { $0.arguments.contains("restart") })
    }

    @MainActor
    func testRestartNowSwitchesToEditedProfileBeforeRestarting() async throws {
        let paths = Self.temporaryConjetPaths()
        let stagingPaths = ConjetPaths(home: paths.rootHome, profileName: "staging")
        try paths.ensureBaseDirectories()
        try stagingPaths.ensureBaseDirectories()
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }
        let persistedEnvironment = paths.rootHome.appendingPathComponent("runtime-environment.json")
        let executor = RecordingCommandExecutor { invocation in
            let invocationPaths = invocation.environment["CONJET_PROFILE"] == "staging" ? stagingPaths : paths
            return Self.processResult(for: invocation, paths: invocationPaths)
        }
        let service = ConjetManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path, "CONJET_PROFILE": "default"],
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            includeLaunchdEnvironment: false,
            persistedRuntimeEnvironmentURL: persistedEnvironment,
            executor: executor
        )
        let app = ConjetAppState(service: service)
        app.snapshot = DashboardSnapshot(
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            dockerSocketPath: paths.dockerSocket.path,
            dockerSocketAvailable: false,
            profiles: ["default", "staging"],
            profileContexts: [
                ConjetProfileContext(paths: paths, isCurrent: true),
                ConjetProfileContext(paths: stagingPaths, isCurrent: false)
            ]
        )
        app.profileConfigDraft = ProfileConfigDraft(profileName: "staging", config: .default)

        await app.saveProfileConfig()
        await app.restartPendingProfileNow()

        XCTAssertEqual(app.currentProfileContext?.name, "staging")
        XCTAssertNil(app.pendingRestartProfileName)
        XCTAssertFalse(app.showProfileRestartPrompt)
        XCTAssertEqual(app.currentVMState, .running)
        let invocations = await executor.invocations
        XCTAssertTrue(invocations.contains { $0.arguments == ["restart", "--json"] })
        XCTAssertFalse(invocations.contains { $0.arguments.starts(with: ["stop"]) })
    }

    func testProfileConfigDraftRejectsInvalidPorts() {
        var draft = ProfileConfigDraft(profileName: "default", config: .default)
        draft.networkLANAllowedPorts = "8080, nope"

        XCTAssertThrowsError(try draft.makeConfig())
    }

    @MainActor
    func testComposeGroupUpUsesProjectContextWithoutRepeatedDockerRefresh() async throws {
        let paths = Self.temporaryConjetPaths()
        try paths.ensureBaseDirectories()
        FileManager.default.createFile(atPath: paths.dockerSocket.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }

        let executor = RecordingCommandExecutor { invocation in
            Self.processResult(for: invocation, paths: paths)
        }
        let service = ConjetManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path],
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            executor: executor
        )
        let app = ConjetAppState(service: service)
        let container = DockerContainer(
            id: "api",
            name: "chum-mem-api-1",
            image: "chum-mem-api",
            state: "exited",
            status: "Exited (0)",
            labels: "com.docker.compose.project=chum-mem,com.docker.compose.service=api,com.docker.compose.project.working_dir=/tmp/chum-mem,com.docker.compose.project.config_files=/tmp/chum-mem/compose.yml"
        )
        let group = try XCTUnwrap(ContainerGrouping.groups(containers: [container]).first)

        await app.containerGroupAction("up", group: group)

        let invocations = await executor.invocations
        let composeInvocation = try XCTUnwrap(invocations.first { $0.displayName == "Compose Up chum-mem" })
        XCTAssertEqual(composeInvocation.workingDirectory?.path, "/tmp/chum-mem")
        XCTAssertTrue(composeInvocation.arguments.contains("compose"))
        XCTAssertTrue(composeInvocation.arguments.contains("-p"))
        XCTAssertTrue(composeInvocation.arguments.contains("chum-mem"))
        XCTAssertTrue(composeInvocation.arguments.contains("-f"))
        XCTAssertTrue(composeInvocation.arguments.contains("/tmp/chum-mem/compose.yml"))
        XCTAssertTrue(composeInvocation.arguments.contains("up"))
        XCTAssertTrue(composeInvocation.arguments.contains("--detach"))
    }

    @MainActor
    func testComposeGroupDownUsesProjectContext() async throws {
        let paths = Self.temporaryConjetPaths()
        try paths.ensureBaseDirectories()
        FileManager.default.createFile(atPath: paths.dockerSocket.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }

        let executor = RecordingCommandExecutor { invocation in
            Self.processResult(for: invocation, paths: paths)
        }
        let service = ConjetManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path],
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            executor: executor
        )
        let app = ConjetAppState(service: service)
        let container = DockerContainer(
            id: "api",
            name: "chum-mem-api-1",
            image: "chum-mem-api",
            state: "running",
            status: "Up 2 minutes",
            labels: "com.docker.compose.project=chum-mem,com.docker.compose.service=api,com.docker.compose.project.working_dir=/tmp/chum-mem,com.docker.compose.project.config_files=/tmp/chum-mem/compose.yml"
        )
        let group = try XCTUnwrap(ContainerGrouping.groups(containers: [container]).first)

        await app.containerGroupAction("down", group: group)

        let invocations = await executor.invocations
        let composeInvocation = try XCTUnwrap(invocations.first { $0.displayName == "Compose Down chum-mem" })
        XCTAssertEqual(composeInvocation.workingDirectory?.path, "/tmp/chum-mem")
        XCTAssertTrue(composeInvocation.arguments.contains("compose"))
        XCTAssertTrue(composeInvocation.arguments.contains("-p"))
        XCTAssertTrue(composeInvocation.arguments.contains("chum-mem"))
        XCTAssertTrue(composeInvocation.arguments.contains("-f"))
        XCTAssertTrue(composeInvocation.arguments.contains("/tmp/chum-mem/compose.yml"))
        XCTAssertTrue(composeInvocation.arguments.contains("down"))
        XCTAssertFalse(composeInvocation.arguments.contains("--detach"))
    }

    @MainActor
    func testComposeGroupStopUsesProjectContextWithoutDown() async throws {
        let paths = Self.temporaryConjetPaths()
        try paths.ensureBaseDirectories()
        FileManager.default.createFile(atPath: paths.dockerSocket.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }

        let executor = RecordingCommandExecutor { invocation in
            Self.processResult(for: invocation, paths: paths)
        }
        let service = ConjetManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path],
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            executor: executor
        )
        let app = ConjetAppState(service: service)
        let container = DockerContainer(
            id: "api",
            name: "chum-mem-api-1",
            image: "chum-mem-api",
            state: "running",
            status: "Up 2 minutes",
            labels: "com.docker.compose.project=chum-mem,com.docker.compose.service=api,com.docker.compose.project.working_dir=/tmp/chum-mem,com.docker.compose.project.config_files=/tmp/chum-mem/compose.yml"
        )
        let group = try XCTUnwrap(ContainerGrouping.groups(containers: [container]).first)

        await app.containerGroupAction("stop", group: group)

        let invocations = await executor.invocations
        let composeInvocation = try XCTUnwrap(invocations.first { $0.displayName == "Compose Stop chum-mem" })
        XCTAssertEqual(composeInvocation.workingDirectory?.path, "/tmp/chum-mem")
        XCTAssertTrue(composeInvocation.arguments.contains("compose"))
        XCTAssertTrue(composeInvocation.arguments.contains("-p"))
        XCTAssertTrue(composeInvocation.arguments.contains("chum-mem"))
        XCTAssertTrue(composeInvocation.arguments.contains("-f"))
        XCTAssertTrue(composeInvocation.arguments.contains("/tmp/chum-mem/compose.yml"))
        XCTAssertTrue(composeInvocation.arguments.contains("stop"))
        XCTAssertFalse(composeInvocation.arguments.contains("down"))
    }

    @MainActor
    func testComposeGroupRestartUsesProjectContextWithoutRepeatedDockerRefresh() async throws {
        let paths = Self.temporaryConjetPaths()
        try paths.ensureBaseDirectories()
        FileManager.default.createFile(atPath: paths.dockerSocket.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }

        let executor = RecordingCommandExecutor { invocation in
            Self.processResult(for: invocation, paths: paths)
        }
        let service = ConjetManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path],
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            executor: executor
        )
        let app = ConjetAppState(service: service)
        let container = DockerContainer(
            id: "api",
            name: "chum-mem-api-1",
            image: "chum-mem-api",
            state: "running",
            status: "Up 2 minutes",
            labels: "com.docker.compose.project=chum-mem,com.docker.compose.service=api,com.docker.compose.project.working_dir=/tmp/chum-mem,com.docker.compose.project.config_files=/tmp/chum-mem/compose.yml"
        )
        let group = try XCTUnwrap(ContainerGrouping.groups(containers: [container]).first)

        await app.containerGroupAction("restart", group: group)

        let invocations = await executor.invocations
        let composeInvocation = try XCTUnwrap(invocations.first { $0.displayName == "Compose Restart chum-mem" })
        XCTAssertEqual(composeInvocation.workingDirectory?.path, "/tmp/chum-mem")
        XCTAssertTrue(composeInvocation.arguments.contains("compose"))
        XCTAssertTrue(composeInvocation.arguments.contains("-p"))
        XCTAssertTrue(composeInvocation.arguments.contains("chum-mem"))
        XCTAssertTrue(composeInvocation.arguments.contains("-f"))
        XCTAssertTrue(composeInvocation.arguments.contains("/tmp/chum-mem/compose.yml"))
        XCTAssertTrue(composeInvocation.arguments.contains("restart"))
    }

    @MainActor
    func testContainerGroupStopOnlyTargetsRunningContainers() async throws {
        let paths = Self.temporaryConjetPaths()
        try paths.ensureBaseDirectories()
        FileManager.default.createFile(atPath: paths.dockerSocket.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }

        let executor = RecordingCommandExecutor { invocation in
            Self.processResult(for: invocation, paths: paths)
        }
        let service = ConjetManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path],
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            executor: executor
        )
        let app = ConjetAppState(service: service)
        let containers = [
            DockerContainer(
                id: "api",
                name: "demo-api-1",
                image: "demo-api",
                state: "running",
                status: "Up 2 minutes",
                labels: "com.docker.compose.project=demo,com.docker.compose.service=api"
            ),
            DockerContainer(
                id: "worker",
                name: "demo-worker-1",
                image: "demo-worker",
                state: "exited",
                status: "Exited (0)",
                labels: "com.docker.compose.project=demo,com.docker.compose.service=worker"
            )
        ]
        let group = try XCTUnwrap(ContainerGrouping.groups(containers: containers).first)

        await app.containerGroupAction("stop", group: group)

        let invocations = await executor.invocations
        let stopInvocation = try XCTUnwrap(invocations.first { $0.displayName == "Stop demo" })
        XCTAssertTrue(stopInvocation.arguments.contains("stop"))
        XCTAssertTrue(stopInvocation.arguments.contains("api"))
        XCTAssertFalse(stopInvocation.arguments.contains("worker"))
    }

    @MainActor
    func testContainerActionDefersFullRefreshAndOptimisticallyUpdatesSnapshot() async throws {
        let paths = Self.temporaryConjetPaths()
        try paths.ensureBaseDirectories()
        FileManager.default.createFile(atPath: paths.dockerSocket.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }

        let executor = RecordingCommandExecutor { invocation in
            Self.processResult(for: invocation, paths: paths)
        }
        let service = ConjetManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path],
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            executor: executor
        )
        let app = ConjetAppState(service: service)
        let container = DockerContainer(
            id: "api",
            name: "api",
            image: "alpine:3.20",
            state: "exited",
            status: "Exited (0)"
        )
        app.snapshot = DashboardSnapshot(
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            dockerSocketPath: paths.dockerSocket.path,
            dockerSocketAvailable: true,
            dockerReachable: true,
            containers: [container]
        )

        await app.containerAction("start", container: container)

        XCTAssertNil(app.activeCommandLabel)
        XCTAssertEqual(app.snapshot.containers.first?.state, "running")
        XCTAssertEqual(app.snapshot.containers.first?.status, "Up just now")
        XCTAssertEqual(app.snapshot.containerActivity.runningContainers, 1)

        let invocations = await executor.invocations
        XCTAssertEqual(invocations.count, 1)
        XCTAssertTrue(invocations[0].arguments.contains("start"))
        XCTAssertTrue(invocations[0].arguments.contains("api"))
        XCTAssertFalse(invocations.contains { $0.arguments.contains("ps") })
        XCTAssertFalse(invocations.contains { $0.arguments.starts(with: ["profile", "list", "--json"]) })
    }

    @MainActor
    func testStopContainerOptimisticallyRemovesVisibleRowAndKeepsItHiddenAfterRefresh() async throws {
        let paths = Self.temporaryConjetPaths()
        try paths.ensureBaseDirectories()
        FileManager.default.createFile(atPath: paths.dockerSocket.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }

        let container = DockerContainer(
            id: "api",
            name: "api",
            image: "alpine:3.20",
            state: "running",
            status: "Up 2 minutes"
        )
        let executor = RecordingCommandExecutor { invocation in
            if invocation.arguments.contains("ps") {
                return ProcessResult(
                    executable: invocation.executable,
                    arguments: invocation.arguments,
                    exitCode: 0,
                    stdout: """
                    {"ID":"api","Names":"api","Image":"alpine:3.20","Command":"\\"sleep 60\\"","CreatedAt":"2026-06-15 10:00:00 +0800 PST","RunningFor":"2 minutes","Ports":"","State":"exited","Status":"Exited (0)","Size":"0B","Labels":""}
                    """,
                    stderr: ""
                )
            }
            return Self.processResult(for: invocation, paths: paths)
        }
        let service = ConjetManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path],
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            executor: executor
        )
        let app = ConjetAppState(service: service)
        app.snapshot = DashboardSnapshot(
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            dockerSocketPath: paths.dockerSocket.path,
            dockerSocketAvailable: true,
            dockerReachable: true,
            containers: [container],
            stats: [
                DockerStats(
                    container: "api",
                    name: "api",
                    cpuPercent: "1.00%",
                    memoryUsage: "8MiB / 2GiB",
                    memoryPercent: "0.39%",
                    networkIO: "1kB / 2kB",
                    blockIO: "0B / 0B",
                    pids: "1"
                )
            ],
            containerProcesses: [
                ContainerProcess(
                    containerID: "api",
                    containerName: "api",
                    pid: "1",
                    ppid: "0",
                    user: "root",
                    state: "S",
                    command: "sleep 60"
                )
            ],
            refreshStatus: .succeeded
        )
        app.selectedContainerID = "api"

        await app.containerAction("stop", container: container)

        XCTAssertTrue(app.snapshot.containers.isEmpty)
        XCTAssertTrue(app.snapshot.stats.isEmpty)
        XCTAssertTrue(app.snapshot.containerProcesses.isEmpty)
        XCTAssertNil(app.selectedContainerID)
        XCTAssertEqual(app.snapshot.containerActivity.totalContainers, 0)

        await app.refresh()

        XCTAssertTrue(app.snapshot.containers.isEmpty)
        XCTAssertEqual(app.snapshot.containerActivity.totalContainers, 0)
    }

    @MainActor
    func testRefreshPreservesResourceListsWhenDockerProbesFail() async throws {
        let paths = Self.temporaryConjetPaths()
        try paths.ensureBaseDirectories()
        FileManager.default.createFile(atPath: paths.dockerSocket.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }

        let executor = FlakyResourceRefreshExecutor()
        let service = ConjetManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path],
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            executor: executor
        )
        let app = ConjetAppState(service: service)
        app.selectedSection = .containers

        await app.refresh()

        XCTAssertEqual(app.snapshot.containers.map(\.name), ["api"])
        XCTAssertTrue(app.snapshot.images.isEmpty)
        XCTAssertTrue(app.snapshot.volumes.isEmpty)
        XCTAssertEqual(app.snapshot.stats.map(\.name), ["api"])
        XCTAssertEqual(app.snapshot.containerProcesses.map(\.command), ["sleep 60"])

        await app.refresh()

        XCTAssertEqual(app.snapshot.containers.map(\.name), ["api"])
        XCTAssertTrue(app.snapshot.images.isEmpty)
        XCTAssertTrue(app.snapshot.volumes.isEmpty)
        XCTAssertEqual(app.snapshot.stats.map(\.name), ["api"])
        XCTAssertEqual(app.snapshot.containerProcesses.map(\.command), ["sleep 60"])
        XCTAssertEqual(app.snapshot.containerActivity.totalContainers, 1)
        XCTAssertEqual(app.snapshot.containerActivity.processCount, 1)
        XCTAssertTrue(app.snapshot.warnings.contains { $0.contains("docker ps") })
    }

    @MainActor
    func testSuccessfulEmptyResourceRefreshReplacesPreviousResources() {
        let current = DashboardSnapshot(
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            dockerSocketPath: "/tmp/conjet.sock",
            dockerSocketAvailable: true,
            dockerReachable: true,
            containers: [
                DockerContainer(
                    id: "api",
                    name: "api",
                    image: "alpine:3.20",
                    state: "running",
                    status: "Up"
                )
            ],
            dockerNetworks: [
                DockerNetwork(id: "bridge-id", name: "bridge", driver: "bridge", scope: "local")
            ],
            refreshStatus: .succeeded
        )
        let latest = DashboardSnapshot(
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            dockerSocketPath: "/tmp/conjet.sock",
            dockerSocketAvailable: true,
            dockerReachable: true,
            containers: [],
            refreshStatus: DashboardRefreshStatus(
                containersSucceeded: true,
                imagesSucceeded: true,
                volumesSucceeded: true,
                dockerNetworksSucceeded: true,
                statsSucceeded: true,
                processesSucceeded: true,
                networkSucceeded: false
            )
        )

        let merged = ConjetAppState.preservingPreviousResources(current: current, latest: latest)

        XCTAssertTrue(merged.containers.isEmpty)
        XCTAssertEqual(merged.containerActivity.totalContainers, 0)
    }

    @MainActor
    func testNetworkRefreshFailurePreservesPreviousNetworkStatus() {
        let network = ConjetNetworkStatus(
            bridgeEngine: ConjetNetworkBridgeEngine.conjetNetdC.rawValue,
            activeTCPForwards: 2,
            activeUDPForwards: 1,
            failedForwards: 0
        )
        let current = DashboardSnapshot(
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            dockerSocketPath: "/tmp/conjet.sock",
            dockerSocketAvailable: true,
            dockerReachable: true,
            network: network,
            refreshStatus: .succeeded
        )
        let latest = DashboardSnapshot(
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            dockerSocketPath: "/tmp/conjet.sock",
            dockerSocketAvailable: true,
            dockerReachable: true,
            refreshStatus: DashboardRefreshStatus(
                containersSucceeded: true,
                imagesSucceeded: true,
                volumesSucceeded: true,
                statsSucceeded: true,
                processesSucceeded: true,
                networkSucceeded: false
            )
        )

        let merged = ConjetAppState.preservingPreviousResources(current: current, latest: latest)

        XCTAssertEqual(merged.network, network)
    }

    @MainActor
    func testDockerNetworkRefreshFailurePreservesPreviousNetworks() {
        let current = DashboardSnapshot(
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            dockerSocketPath: "/tmp/conjet.sock",
            dockerSocketAvailable: true,
            dockerReachable: true,
            dockerNetworks: [
                DockerNetwork(id: "bridge-id", name: "bridge", driver: "bridge", scope: "local")
            ],
            refreshStatus: .succeeded
        )
        let latest = DashboardSnapshot(
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            dockerSocketPath: "/tmp/conjet.sock",
            dockerSocketAvailable: true,
            dockerReachable: true,
            refreshStatus: DashboardRefreshStatus(
                containersSucceeded: true,
                imagesSucceeded: true,
                volumesSucceeded: true,
                dockerNetworksSucceeded: false,
                statsSucceeded: true,
                processesSucceeded: true,
                networkSucceeded: true
            )
        )

        let merged = ConjetAppState.preservingPreviousResources(current: current, latest: latest)

        XCTAssertEqual(merged.dockerNetworks.map(\.name), ["bridge"])
    }

    @MainActor
    func testDockerEditorBuildsTemporaryContextAndRunsDetachedContainer() async throws {
        let paths = Self.temporaryConjetPaths()
        try paths.ensureBaseDirectories()
        FileManager.default.createFile(atPath: paths.dockerSocket.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }

        let executor = RecordingCommandExecutor { invocation in
            Self.processResult(for: invocation, paths: paths)
        }
        let service = ConjetManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path],
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            executor: executor
        )
        let app = ConjetAppState(service: service)
        app.dockerEditorSource = """
        FROM alpine:3.20
        CMD ["sleep", "60"]
        """
        app.dockerEditorImageTag = "conjet-editor:test"
        app.dockerEditorRunArguments = "-p 8080:80"

        await app.runDockerEditor()

        let invocations = await executor.invocations
        let buildInvocation = try XCTUnwrap(invocations.first { $0.displayName == "Build Dockerfile" })
        XCTAssertEqual(Array(buildInvocation.arguments.suffix(6)), [
            "build",
            "--label", "io.conjet.source=docker-editor",
            "--tag", "conjet-editor:test",
            "."
        ])
        let buildDirectory = try XCTUnwrap(buildInvocation.workingDirectory)
        XCTAssertTrue(buildDirectory.path.contains("conjet-docker-editor-"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: buildDirectory.path))

        let runInvocation = try XCTUnwrap(invocations.first { $0.displayName?.hasPrefix("Run conjet-editor-") == true })
        XCTAssertTrue(runInvocation.arguments.contains("run"))
        XCTAssertTrue(runInvocation.arguments.contains("--detach"))
        XCTAssertTrue(runInvocation.arguments.contains("--rm"))
        XCTAssertTrue(runInvocation.arguments.contains("--name"))
        XCTAssertTrue(runInvocation.arguments.contains("--label"))
        XCTAssertTrue(runInvocation.arguments.contains("io.conjet.source=docker-editor"))
        XCTAssertTrue(runInvocation.arguments.contains("-p"))
        XCTAssertTrue(runInvocation.arguments.contains("8080:80"))
        XCTAssertEqual(runInvocation.arguments.last, "conjet-editor:test")
        XCTAssertNil(app.activeCommandLabel)
        XCTAssertEqual(app.commandLog.count, 2)
        XCTAssertEqual(app.commandLog.first?.label, runInvocation.displayName)
        XCTAssertEqual(app.snapshot.containers.count, 1)
        XCTAssertEqual(app.snapshot.containers.first?.name.hasPrefix("conjet-editor-"), true)
        XCTAssertEqual(app.snapshot.containers.first?.image, "conjet-editor:test")
        XCTAssertEqual(app.snapshot.containers.first?.state, "running")
    }

    @MainActor
    func testPrepareContainerTerminalBuildsEmbeddedInteractiveDockerExecCommand() {
        let paths = Self.temporaryConjetPaths()
        let executor = RecordingCommandExecutor { invocation in
            Self.processResult(for: invocation, paths: paths)
        }
        let service = ConjetManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path],
            conjetTool: Self.tool,
            conjetCoreTool: Self.tool,
            dockerTool: Self.tool,
            executor: executor
        )
        let app = ConjetAppState(service: service)
        app.containerTerminalDebugEnabled = true
        let container = DockerContainer(
            id: "api",
            name: "api",
            image: "ubuntu:24.04",
            state: "running",
            status: "Up"
        )

        let command = app.prepareContainerTerminal(container: container)
        let shellBootstrap = "if [ -x /bin/bash ]; then exec /bin/bash; fi; if command -v bash >/dev/null 2>&1; then exec bash; fi; exec /bin/sh"

        XCTAssertNotNil(command)
        XCTAssertEqual(command?.executable, "/tmp/conjet-test-tool")
        XCTAssertEqual(command?.arguments, [
            "--debug",
            "--host",
            "unix://\(paths.dockerSocket.path)",
            "exec",
            "-it",
            "api",
            "/bin/sh",
            "-lc",
            shellBootstrap
        ])
        XCTAssertTrue(command?.environment.contains("TERM=xterm-256color") == true)
        XCTAssertTrue(command?.debugEnabled == true)
        XCTAssertTrue(command?.commandLine.contains("/tmp/conjet-test-tool --debug --host unix://\(paths.dockerSocket.path) exec -it api /bin/sh -lc") == true)
        XCTAssertTrue(command?.commandLine.contains("exec /bin/bash") == true)
        XCTAssertTrue(command?.commandLine.contains("exec /bin/sh") == true)
        XCTAssertNil(app.containerTerminalError)
        XCTAssertEqual(app.commandLog.first?.label, "Terminal api")
        XCTAssertTrue(app.commandLog.first?.stdout.contains("started embedded terminal for api using /bin/sh") == true)
    }

    private static let tool = ResolvedTool(executable: "/tmp/conjet-test-tool", source: "test")

    private static func temporaryConjetPaths() -> ConjetPaths {
        let home = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cj-as-\(UUID().uuidString.prefix(8))", isDirectory: true)
        return ConjetPaths(home: home)
    }

    private static func processResult(
        for invocation: CommandInvocation,
        paths: ConjetPaths
    ) -> ProcessResult {
        if invocation.arguments == ["restart", "--json"] {
            return ProcessResult(
                executable: invocation.executable,
                arguments: invocation.arguments,
                exitCode: 0,
                stdout: restartJSON(paths: paths),
                stderr: ""
            )
        }
        if invocation.arguments == ["status", "--json"] {
            return ProcessResult(
                executable: invocation.executable,
                arguments: invocation.arguments,
                exitCode: 0,
                stdout: daemonResponseJSON(paths: paths),
                stderr: ""
            )
        }
        if invocation.arguments == ["profile", "list", "--json"] {
            return ProcessResult(
                executable: invocation.executable,
                arguments: invocation.arguments,
                exitCode: 0,
                stdout: #"["default"]"#,
                stderr: ""
            )
        }
        return ProcessResult(
            executable: invocation.executable,
            arguments: invocation.arguments,
            exitCode: 0,
            stdout: "",
            stderr: ""
        )
    }

    private static func restartJSON(paths: ConjetPaths) -> String {
        """
        {
          "started": \(daemonResponseJSON(paths: paths))
        }
        """
    }

    private static func daemonResponseJSON(paths: ConjetPaths) -> String {
        """
        {
          "ok": true,
          "message": "running",
          "status": {
            "pid": 456,
            "startedAt": "2026-06-13T09:00:00Z",
            "state": "warm-idle",
            "socketPath": "\(paths.socket.path)",
            "host": {
              "macOSVersion": "26.4.1",
              "buildVersion": "25E253",
              "architecture": "arm64",
              "cpuBrand": "Apple",
              "memoryBytes": 17179869184,
              "isAppleSilicon": true,
              "virtualizationFrameworkAvailable": true,
              "rosettaLinuxSupportLikelyAvailable": true,
              "lowPowerModeEnabled": false,
              "thermalState": "nominal",
              "requiredEntitlements": ["com.apple.security.virtualization"]
            },
            "config": {},
            "memoryPolicy": {
              "profile": "balanced",
              "configuredMemoryMiB": 8192,
              "recommendedMemoryMiB": 8192,
              "lazyRuntimeServices": false,
              "lazyNetworkHelpers": true,
              "reclaimIdleHelpersAfterSeconds": 300,
              "idleWakeupBudgetPerSecond": 1
            },
            "vm": {
              "state": "running",
              "configured": true,
              "manifestPath": "\(paths.vmManifest.path)",
              "dockerSocketPath": "\(paths.dockerSocket.path)",
              "message": "running",
              "events": []
            },
            "network": {
              "activeTCPForwards": 0,
              "activeUDPForwards": 0,
              "failedForwards": 0,
              "conflictCount": 0,
              "staleForwards": 0,
              "forwards": [],
              "messages": []
            }
          }
        }
        """
    }
}

private actor RecordingCommandExecutor: CommandExecuting {
    private var recordedInvocations: [CommandInvocation] = []
    private let handler: @Sendable (CommandInvocation) -> ProcessResult

    init(handler: @escaping @Sendable (CommandInvocation) -> ProcessResult) {
        self.handler = handler
    }

    var invocations: [CommandInvocation] { recordedInvocations }

    func run(_ invocation: CommandInvocation) async -> ProcessResult {
        recordedInvocations.append(invocation)
        return handler(invocation)
    }
}

private actor FlakyResourceRefreshExecutor: CommandExecuting {
    private var recordedInvocations: [CommandInvocation] = []
    private var attemptsByCommand: [String: Int] = [:]

    var invocations: [CommandInvocation] { recordedInvocations }

    func run(_ invocation: CommandInvocation) async -> ProcessResult {
        recordedInvocations.append(invocation)
        let key = Self.commandKey(for: invocation.arguments)
        attemptsByCommand[key, default: 0] += 1
        let attempt = attemptsByCommand[key] ?? 1

        if attempt > 1, Self.flakyCommandKeys.contains(key) {
            return Self.result(invocation, exitCode: 1, stderr: "\(key) unavailable")
        }

        switch key {
        case "ps":
            return Self.result(invocation, stdout: """
            {"ID":"api","Names":"api","Image":"alpine:3.20","Command":"\\"sleep 60\\"","CreatedAt":"2026-06-15 10:00:00 +0800 PST","RunningFor":"2 minutes","Ports":"","State":"running","Status":"Up 2 minutes","Size":"0B","Labels":""}
            """)
        case "images":
            return Self.result(invocation, stdout: """
            {"ID":"sha256:alpine","Repository":"alpine","Tag":"3.20","Size":"7.8MB","CreatedAt":"2026-06-01 10:00:00 +0800 PST","CreatedSince":"2 weeks ago"}
            """)
        case "volume-ls":
            return Self.result(invocation, stdout: """
            {"Name":"api-data","Driver":"local","Scope":"local","Mountpoint":"/var/lib/docker/volumes/api-data/_data","Labels":"","Size":"42MB"}
            """)
        case "network-ls":
            return Self.result(invocation, stdout: """
            {"ID":"bridge-id","Name":"bridge","Driver":"bridge","Scope":"local","IPv6":"false","Internal":"false","Labels":""}
            """)
        case "system-df":
            return Self.result(invocation, stdout: #"{"Volumes":[{"Name":"api-data","Size":"42MB"}]}"#)
        case "stats":
            return Self.result(invocation, stdout: """
            {"Container":"api","Name":"api","CPUPerc":"1.00%","MemUsage":"8MiB / 2GiB","MemPerc":"0.39%","NetIO":"1kB / 2kB","BlockIO":"0B / 0B","PIDs":"1"}
            """)
        case "top":
            return Self.result(invocation, stdout: """
            PID PPID USER STAT COMMAND
            1 0 root S sleep 60
            """)
        default:
            return Self.result(invocation)
        }
    }

    private static let flakyCommandKeys: Set<String> = [
        "ps",
        "images",
        "volume-ls",
        "network-ls",
        "stats",
        "top"
    ]

    private static func commandKey(for arguments: [String]) -> String {
        if arguments.contains("ps") {
            return "ps"
        }
        if arguments.contains("images") {
            return "images"
        }
        if arguments.contains("volume"), arguments.contains("ls") {
            return "volume-ls"
        }
        if arguments.contains("network"), arguments.contains("ls") {
            return "network-ls"
        }
        if arguments.contains("system"), arguments.contains("df") {
            return "system-df"
        }
        if arguments.contains("stats") {
            return "stats"
        }
        if arguments.contains("top") {
            return "top"
        }
        return "other"
    }

    private static func result(
        _ invocation: CommandInvocation,
        exitCode: Int32 = 0,
        stdout: String = "",
        stderr: String = ""
    ) -> ProcessResult {
        ProcessResult(
            executable: invocation.executable,
            arguments: invocation.arguments,
            exitCode: exitCode,
            stdout: stdout,
            stderr: stderr
        )
    }
}

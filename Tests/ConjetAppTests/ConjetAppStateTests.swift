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

    @MainActor
    func testRestartRuntimeAppliesStartedDaemonVMStatus() async {
        let paths = Self.temporaryConjetPaths()
        let executor = RecordingCommandExecutor { invocation in
            Self.processResult(for: invocation, paths: paths)
        }
        let service = ConjetManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path],
            conjetTool: Self.tool,
            conjetdTool: Self.tool,
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
    func testComposeGroupUpUsesProjectContextAndStartsReadinessPolling() async throws {
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
            conjetdTool: Self.tool,
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
        XCTAssertEqual(app.activeContainerGroupID, "compose:chum-mem")
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
            conjetdTool: Self.tool,
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
        XCTAssertEqual(app.activeContainerGroupID, "compose:chum-mem")
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
            conjetdTool: Self.tool,
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
    func testComposeGroupRestartUsesProjectContextAndStartsReadinessPolling() async throws {
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
            conjetdTool: Self.tool,
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
        XCTAssertEqual(app.activeContainerGroupID, "compose:chum-mem")
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
            conjetdTool: Self.tool,
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
            conjetdTool: Self.tool,
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
            conjetdTool: Self.tool,
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
    func testDockerEditorBuildsTemporaryContextAndRunsDetachedContainer() async throws {
        let paths = Self.temporaryConjetPaths()
        try paths.ensureBaseDirectories()
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }

        let executor = RecordingCommandExecutor { invocation in
            Self.processResult(for: invocation, paths: paths)
        }
        let service = ConjetManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path],
            conjetTool: Self.tool,
            conjetdTool: Self.tool,
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
    }

    private static let tool = ResolvedTool(executable: "/tmp/conjet-test-tool", source: "test")

    private static func temporaryConjetPaths() -> ConjetPaths {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("conjet-app-state-tests-\(UUID().uuidString)", isDirectory: true)
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

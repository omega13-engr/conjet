@testable import ConjetAppCore
import ConjetCore
import XCTest

final class ConjetAppCoreTests: XCTestCase {
    func testDecodesDockerContainerJSONLines() {
        let output = """
        {"ID":"abcdef123456","Names":"api","Image":"ubuntu:24.04","Command":"\\"sleep 60\\"","CreatedAt":"2026-06-11 08:00:00 +0800 PST","RunningFor":"2 minutes","Ports":"127.0.0.1:8080->80/tcp","State":"running","Status":"Up 2 minutes (healthy)","Size":"0B","Labels":"com.docker.compose.project=demo,com.docker.compose.service=api"}
        {"ID":"fedcba654321","Names":"worker","Image":"alpine:3.20","Command":"\\"sh\\"","CreatedAt":"2026-06-11 08:01:00 +0800 PST","RunningFor":"1 minute","Ports":"","State":"exited","Status":"Exited (0)","Size":"0B"}
        """

        let containers = DockerJSONLines.decode(DockerContainer.self, from: output)

        XCTAssertEqual(containers.count, 2)
        XCTAssertEqual(containers[0].id, "abcdef123456")
        XCTAssertEqual(containers[0].name, "api")
        XCTAssertEqual(containers[0].state, "running")
        XCTAssertEqual(containers[0].healthState, .healthy)
        XCTAssertEqual(containers[0].composeProject, "demo")
        XCTAssertEqual(containers[0].composeService, "api")
        XCTAssertEqual(containers[1].image, "alpine:3.20")
        XCTAssertEqual(containers[1].labels, "")
    }

    func testContainerGroupingBuildsComposeGroupsWithHealthReadiness() {
        let containers = [
            DockerContainer(
                id: "api",
                name: "demo-api-1",
                image: "demo-api",
                state: "running",
                status: "Up 20 seconds (health: starting)",
                labels: "com.docker.compose.project=demo,com.docker.compose.service=api,com.docker.compose.project.working_dir=/tmp/demo,com.docker.compose.project.config_files=/tmp/demo/compose.yml"
            ),
            DockerContainer(
                id: "db",
                name: "demo-db-1",
                image: "postgres:18",
                state: "running",
                status: "Up 20 seconds (healthy)",
                labels: "com.docker.compose.project=demo,com.docker.compose.service=db,com.docker.compose.project.working_dir=/tmp/demo,com.docker.compose.project.config_files=/tmp/demo/compose.yml"
            ),
            DockerContainer(
                id: "standalone",
                name: "shell",
                image: "alpine:3.20",
                state: "exited",
                status: "Exited (0)"
            )
        ]

        let groups = ContainerGrouping.groups(containers: containers)

        XCTAssertEqual(groups.map(\.title), ["demo"])
        XCTAssertEqual(groups[0].id, "compose:demo")
        XCTAssertEqual(groups[0].readiness, .starting)
        XCTAssertEqual(groups[0].healthyCount, 1)
        XCTAssertEqual(groups[0].startingHealthCount, 1)
        XCTAssertEqual(groups[0].composeWorkingDirectory, "/tmp/demo")
        XCTAssertEqual(groups[0].composeConfigFiles, ["/tmp/demo/compose.yml"])
        XCTAssertTrue(groups[0].canRunComposeUp)
    }

    func testContainerGroupingMarksUnhealthyComposeGroupDegraded() throws {
        let containers = [
            DockerContainer(
                id: "api",
                name: "demo-api-1",
                image: "demo-api",
                state: "running",
                status: "Up 5 minutes (unhealthy)",
                labels: "com.docker.compose.project=demo,com.docker.compose.service=api"
            ),
            DockerContainer(
                id: "worker",
                name: "demo-worker-1",
                image: "demo-worker",
                state: "running",
                status: "Up 5 minutes",
                labels: "com.docker.compose.project=demo,com.docker.compose.service=worker"
            )
        ]

        let group = try XCTUnwrap(ContainerGrouping.groups(containers: containers).first)

        XCTAssertEqual(group.readiness, .degraded)
    }

    func testDecodesDockerStatsJSONLines() {
        let output = """
        {"Container":"abcdef123456","Name":"api","CPUPerc":"1.25%","MemUsage":"16MiB / 2GiB","MemPerc":"0.78%","NetIO":"1.2kB / 900B","BlockIO":"0B / 0B","PIDs":"4"}
        """

        let stats = DockerJSONLines.decode(DockerStats.self, from: output)

        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats[0].name, "api")
        XCTAssertEqual(stats[0].cpuPercent, "1.25%")
        XCTAssertEqual(stats[0].pids, "4")
    }

    func testDecodesDockerVolumeJSONLinesWithSize() {
        let output = """
        {"Name":"db_data","Driver":"local","Scope":"local","Mountpoint":"/var/lib/docker/volumes/db_data/_data","Labels":"project=test","Size":"42.5MB"}
        """

        let volumes = DockerJSONLines.decode(DockerVolume.self, from: output)

        XCTAssertEqual(volumes.count, 1)
        XCTAssertEqual(volumes[0].name, "db_data")
        XCTAssertEqual(volumes[0].driver, "local")
        XCTAssertEqual(volumes[0].size, "42.5MB")
        XCTAssertEqual(volumes[0].displaySize, "42.5MB")
    }

    func testDecodesDockerNetworkJSONLines() {
        let output = """
        {"ID":"net123","Name":"conjet_default","Driver":"bridge","Scope":"local","IPv6":"false","Internal":"false","Labels":"com.docker.compose.project=conjet"}
        """

        let networks = DockerJSONLines.decode(DockerNetwork.self, from: output)

        XCTAssertEqual(networks.count, 1)
        XCTAssertEqual(networks[0].id, "net123")
        XCTAssertEqual(networks[0].name, "conjet_default")
        XCTAssertEqual(networks[0].driver, "bridge")
        XCTAssertEqual(networks[0].detailText, "bridge - local")
    }

    func testParsesDockerSystemDiskUsageVolumeSizes() {
        let output = """
        {"Volumes":[{"Name":"chroma_data","Size":"672.7MB"},{"Name":"postgres_data","Size":"6.957GB"}]}
        """

        let usage = DockerSystemDiskUsage.volumeUsageByName(from: output)

        XCTAssertEqual(usage["chroma_data"]?.size, "672.7MB")
        XCTAssertEqual(usage["postgres_data"]?.size, "6.957GB")
    }

    func testContainerActivitySnapshotAggregatesContainerRuntimeOnly() {
        let stats = DockerJSONLines.decode(DockerStats.self, from: """
        {"Container":"abcdef123456","Name":"api","CPUPerc":"1.25%","MemUsage":"16MiB / 2GiB","MemPerc":"0.78%","NetIO":"1.2kB / 900B","BlockIO":"0B / 0B","PIDs":"4"}
        {"Container":"fedcba654321","Name":"worker","CPUPerc":"2.50%","MemUsage":"32MiB / 2GiB","MemPerc":"1.56%","NetIO":"2kB / 1kB","BlockIO":"0B / 0B","PIDs":"2"}
        """)
        let containers = [
            DockerContainer(id: "abcdef123456", name: "api", image: "ubuntu:24.04", state: "running", status: "Up"),
            DockerContainer(id: "fedcba654321", name: "worker", image: "alpine:3.20", state: "exited", status: "Exited")
        ]
        let processes = [
            ContainerProcess(containerID: "abcdef123456", containerName: "api", pid: "1", ppid: "0", user: "root", state: "S", command: "sleep 60")
        ]

        let activity = ContainerActivitySnapshot(containers: containers, stats: stats, processes: processes)

        XCTAssertEqual(activity.totalContainers, 2)
        XCTAssertEqual(activity.runningContainers, 1)
        XCTAssertEqual(activity.stoppedContainers, 1)
        XCTAssertEqual(activity.statsSampleCount, 2)
        XCTAssertEqual(activity.processCount, 1)
        XCTAssertEqual(activity.totalCPUPercent, 3.75, accuracy: 0.001)
        XCTAssertEqual(activity.busiestContainerName, "worker")
    }

    func testCommandInvocationRendersQuotedAuditCommand() {
        let invocation = CommandInvocation(
            executable: "/usr/bin/env",
            arguments: ["docker", "compose", "-f", "compose dev.yml", "up"],
            displayName: "Compose Up"
        )

        XCTAssertEqual(invocation.commandLine, "/usr/bin/env docker compose -f 'compose dev.yml' up")
    }

    func testResolvedToolBuildsInvocationWithPrefix() {
        let tool = ResolvedTool(executable: "/usr/bin/env", argumentsPrefix: ["docker"], source: "test")
        let invocation = tool.invocation(
            arguments: ["ps"],
            displayName: "Docker PS",
            environment: ["CONJET_HOME": "/tmp/conjet-home"]
        )

        XCTAssertEqual(invocation.executable, "/usr/bin/env")
        XCTAssertEqual(invocation.arguments, ["docker", "ps"])
        XCTAssertEqual(invocation.displayName, "Docker PS")
        XCTAssertEqual(invocation.environment["CONJET_HOME"], "/tmp/conjet-home")
    }

    func testFindExecutableUsesProvidedPath() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("conjet-tool-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("conjet-test-tool")
        FileManager.default.createFile(atPath: executable.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        XCTAssertEqual(
            ConjetToolResolver.findExecutable(
                named: "conjet-test-tool",
                environment: ["PATH": directory.path]
            ),
            executable.path
        )
    }

    func testLoadSnapshotDeduplicatesExactDockerImageRows() async throws {
        let paths = try Self.makeTemporaryConjetPaths()
        try paths.ensureBaseDirectories()
        FileManager.default.createFile(atPath: paths.dockerSocket.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }

        let executor = RecordingCommandExecutor { invocation in
            Self.stubbedSnapshotResult(for: invocation, imageOutput: """
            {"ID":"sha256:stable","Repository":"nginx","Tag":"alpine","Size":"92.6MB","CreatedAt":"2026-05-23 02:30:41 +0800 PST","CreatedSince":"3 weeks ago"}
            {"ID":"sha256:stable","Repository":"nginx","Tag":"alpine","Size":"92.6MB","CreatedAt":"2026-05-23 02:30:41 +0800 PST","CreatedSince":"3 weeks ago"}
            {"ID":"sha256:stable","Repository":"nginx","Tag":"1.31-alpine","Size":"92.6MB","CreatedAt":"2026-05-23 02:30:41 +0800 PST","CreatedSince":"3 weeks ago"}
            """)
        }
        let service = Self.makeService(paths: paths, executor: executor)

        let snapshot = await service.loadSnapshot()

        XCTAssertTrue(snapshot.dockerReachable)
        XCTAssertEqual(snapshot.images.map { $0.reference }, ["nginx:alpine", "nginx:1.31-alpine"])
        XCTAssertEqual(Set(snapshot.images.map { $0.selectionID }).count, 2)
    }

    func testLoadSnapshotPicksUpPersistedRuntimeBindingAfterServiceCreation() async throws {
        let paths = try Self.makeTemporaryConjetPaths()
        try paths.ensureBaseDirectories()
        FileManager.default.createFile(atPath: paths.dockerSocket.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }

        let persistedEnvironment = paths.rootHome.appendingPathComponent("runtime-environment.json")
        let executor = RecordingCommandExecutor { invocation in
            Self.stubbedSnapshotResult(for: invocation, imageOutput: "")
        }
        let tool = ResolvedTool(executable: "/tmp/conjet-test-tool", source: "test")
        let service = ConjetManagementService(
            environment: ["PATH": "/usr/bin:/bin"],
            conjetTool: tool,
            conjetCoreTool: tool,
            dockerTool: tool,
            includeLaunchdEnvironment: false,
            persistedRuntimeEnvironmentURL: persistedEnvironment,
            executor: executor
        )

        try ConjetEnvironment.persistRuntimeBinding(
            environment: ["CONJET_HOME": paths.rootHome.path, "CONJET_PROFILE": paths.profileName],
            to: persistedEnvironment
        )
        let snapshot = await service.loadSnapshot()

        XCTAssertEqual(snapshot.dockerSocketPath, paths.dockerSocket.path)
        XCTAssertTrue(snapshot.dockerReachable)

        let invocations = await executor.invocations
        XCTAssertFalse(invocations.isEmpty)
        XCTAssertTrue(invocations.allSatisfy { $0.environment["CONJET_HOME"] == paths.rootHome.path })
        XCTAssertTrue(invocations.allSatisfy { $0.environment["CONJET_PROFILE"] == paths.profileName })
    }

    func testDockerCommandsUseProfileDockerSocketWhenDaemonSocketIsOverridden() async throws {
        let paths = try Self.makeTemporaryConjetPaths()
        try paths.ensureBaseDirectories()
        let customDaemonSocket = paths.runDirectory.appendingPathComponent("custom-conjetd.sock").path
        try ConjetConfig(socketPath: customDaemonSocket).save(paths: paths)
        FileManager.default.createFile(atPath: paths.dockerSocket.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }

        let executor = RecordingCommandExecutor { invocation in
            Self.stubbedSnapshotResult(for: invocation, imageOutput: "")
        }
        let service = Self.makeService(paths: paths, executor: executor)

        _ = await service.loadSnapshot()

        let dockerHosts = await executor.invocations.compactMap { invocation -> String? in
            guard let index = invocation.arguments.firstIndex(of: "--host"),
                  invocation.arguments.indices.contains(index + 1) else {
                return nil
            }
            return invocation.arguments[index + 1]
        }

        XCTAssertFalse(dockerHosts.isEmpty)
        XCTAssertTrue(dockerHosts.allSatisfy { $0 == "unix://\(paths.dockerSocket.path)" })
        XCTAssertFalse(dockerHosts.contains("unix://\(customDaemonSocket)"))
    }

    func testDockerExecTerminalCommandUsesProfileSocketAndShellFallback() throws {
        let paths = try Self.makeTemporaryConjetPaths()
        let executor = RecordingCommandExecutor { invocation in
            Self.stubbedSnapshotResult(for: invocation, imageOutput: "")
        }
        let service = Self.makeService(paths: paths, executor: executor)
        let container = DockerContainer(
            id: "api",
            name: "api",
            image: "ubuntu:24.04",
            state: "running",
            status: "Up"
        )

        let command = try service.dockerExecTerminalCommand(container: container)
        let shellBootstrap = "if [ -x /bin/bash ]; then exec /bin/bash; fi; if command -v bash >/dev/null 2>&1; then exec bash; fi; exec /bin/sh"

        XCTAssertEqual(command.title, "Terminal api")
        XCTAssertEqual(command.executable, "/tmp/conjet-test-tool")
        XCTAssertEqual(command.arguments, [
            "--host",
            "unix://\(paths.dockerSocket.path)",
            "exec",
            "-it",
            "api",
            "/bin/sh",
            "-lc",
            shellBootstrap
        ])
        XCTAssertTrue(command.environment.contains("CONJET_HOME=\(paths.rootHome.path)"))
        XCTAssertTrue(command.environment.contains("TERM=xterm-256color"))
        XCTAssertEqual(command.containerID, "api")
        XCTAssertEqual(command.containerName, "api")
        XCTAssertEqual(command.shellPath, "/bin/sh")
        XCTAssertEqual(command.dockerSocketPath, paths.dockerSocket.path)
        XCTAssertTrue(command.commandLine.contains("CONJET_HOME=\(paths.rootHome.path)"))
        XCTAssertTrue(command.commandLine.contains("TERM=xterm-256color"))
        XCTAssertTrue(command.commandLine.contains("PATH="))
        XCTAssertTrue(command.commandLine.contains("/tmp/conjet-test-tool --host unix://\(paths.dockerSocket.path) exec -it api /bin/sh -lc"))
        XCTAssertTrue(command.commandLine.contains("exec /bin/bash"))
        XCTAssertTrue(command.commandLine.contains("exec /bin/sh"))
    }

    func testDockerExecTerminalCommandCanEnableDockerDebugMode() throws {
        let paths = try Self.makeTemporaryConjetPaths()
        let executor = RecordingCommandExecutor { invocation in
            Self.stubbedSnapshotResult(for: invocation, imageOutput: "")
        }
        let service = Self.makeService(paths: paths, executor: executor)
        let container = DockerContainer(
            id: "api",
            name: "api",
            image: "ubuntu:24.04",
            state: "running",
            status: "Up"
        )

        let command = try service.dockerExecTerminalCommand(container: container, debugEnabled: true)

        XCTAssertEqual(Array(command.arguments.prefix(3)), ["--debug", "--host", "unix://\(paths.dockerSocket.path)"])
        XCTAssertTrue(command.debugEnabled)
        XCTAssertTrue(command.commandLine.contains("/tmp/conjet-test-tool --debug --host unix://\(paths.dockerSocket.path) exec -it api /bin/sh -lc"))
    }

    func testDockerExecTerminalCommandRejectsStoppedContainers() throws {
        let paths = try Self.makeTemporaryConjetPaths()
        let executor = RecordingCommandExecutor { invocation in
            Self.stubbedSnapshotResult(for: invocation, imageOutput: "")
        }
        let service = Self.makeService(paths: paths, executor: executor)
        let container = DockerContainer(
            id: "api",
            name: "api",
            image: "ubuntu:24.04",
            state: "exited",
            status: "Exited (0)"
        )

        XCTAssertThrowsError(try service.dockerExecTerminalCommand(container: container))
    }

    func testLoadSnapshotUsesDirectStatusAndProfileDiscoveryWithoutConjetCommands() async throws {
        let paths = try Self.makeTemporaryConjetPaths()
        try paths.ensureBaseDirectories()
        let profilesDirectory = paths.rootHome.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(
            at: profilesDirectory.appendingPathComponent("dev", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: profilesDirectory.appendingPathComponent(".hidden", isDirectory: true),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: paths.dockerSocket.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }

        let executor = RecordingCommandExecutor { invocation in
            Self.stubbedSnapshotResult(for: invocation, imageOutput: "")
        }
        let service = Self.makeService(paths: paths, executor: executor)

        let snapshot = await service.loadSnapshot()
        let devPaths = ConjetPaths(home: paths.rootHome, profileName: "dev")

        XCTAssertEqual(snapshot.profiles, ["default", "dev"])
        XCTAssertEqual(snapshot.profileContexts.map(\.name), ["default", "dev"])
        XCTAssertEqual(snapshot.profileContexts.first(where: { $0.isCurrent })?.name, "default")
        XCTAssertEqual(snapshot.profileContexts.first(where: { $0.name == "dev" })?.dockerSocketPath, devPaths.dockerSocket.path)
        XCTAssertEqual(snapshot.daemonResponse?.ok, false)

        let invocations = await executor.invocations
        XCTAssertFalse(invocations.contains { $0.arguments == ["status", "--json"] })
        XCTAssertFalse(invocations.contains { $0.arguments == ["profile", "list", "--json"] })
        XCTAssertTrue(invocations.allSatisfy {
            $0.arguments.starts(with: ["--host", "unix://\(paths.dockerSocket.path)"])
        })
    }

    func testLoadVolumesCanSkipUsageEnrichmentForFastList() async throws {
        let paths = try Self.makeTemporaryConjetPaths()
        try paths.ensureBaseDirectories()
        FileManager.default.createFile(atPath: paths.dockerSocket.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }

        let executor = RecordingCommandExecutor { invocation in
            Self.stubbedSnapshotResult(for: invocation, imageOutput: "")
        }
        let service = Self.makeService(paths: paths, executor: executor)

        _ = await service.loadVolumes(includeUsage: false)

        let invocations = await executor.invocations
        XCTAssertTrue(invocations.contains { $0.arguments.contains("volume") && $0.arguments.contains("ls") })
        XCTAssertFalse(invocations.contains { $0.arguments.contains("system") && $0.arguments.contains("df") })
    }

    func testLoadSnapshotDefaultSkipsExpensiveActivityAndUsageProbes() async throws {
        let paths = try Self.makeTemporaryConjetPaths()
        try paths.ensureBaseDirectories()
        FileManager.default.createFile(atPath: paths.dockerSocket.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }

        let executor = RecordingCommandExecutor { invocation in
            Self.stubbedSnapshotResult(for: invocation, imageOutput: "", containerOutput: """
            {"ID":"api","Names":"api","Image":"alpine:3.20","Command":"\\"sleep 60\\"","CreatedAt":"2026-06-15 10:00:00 +0800 PST","RunningFor":"2 minutes","Ports":"","State":"running","Status":"Up 2 minutes","Size":"0B","Labels":""}
            """)
        }
        let service = Self.makeService(paths: paths, executor: executor)

        let snapshot = await service.loadSnapshot()

        let invocations = await executor.invocations
        XCTAssertTrue(snapshot.refreshStatus.containersSucceeded)
        XCTAssertTrue(snapshot.refreshStatus.dockerNetworksSucceeded)
        XCTAssertEqual(snapshot.dockerNetworks.map(\.name), ["bridge"])
        XCTAssertFalse(snapshot.refreshStatus.statsSucceeded)
        XCTAssertFalse(snapshot.refreshStatus.processesSucceeded)
        XCTAssertTrue(invocations.contains { $0.arguments.contains("network") && $0.arguments.contains("ls") })
        XCTAssertFalse(invocations.contains { $0.arguments.contains("stats") })
        XCTAssertFalse(invocations.contains { $0.arguments.contains("top") })
        XCTAssertFalse(invocations.contains { $0.arguments.contains("system") && $0.arguments.contains("df") })
    }

    func testLoadSnapshotStatusOnlySkipsDockerInventoryProbes() async throws {
        let paths = try Self.makeTemporaryConjetPaths()
        try paths.ensureBaseDirectories()
        FileManager.default.createFile(atPath: paths.dockerSocket.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }

        let executor = RecordingCommandExecutor { invocation in
            Self.stubbedSnapshotResult(for: invocation, imageOutput: "", containerOutput: """
            {"ID":"api","Names":"api","Image":"alpine:3.20","Command":"\\"sleep 60\\"","CreatedAt":"2026-06-15 10:00:00 +0800 PST","RunningFor":"2 minutes","Ports":"","State":"running","Status":"Up 2 minutes","Size":"0B","Labels":""}
            """)
        }
        let service = Self.makeService(paths: paths, executor: executor)

        let snapshot = await service.loadSnapshot(scope: .statusOnly)

        let invocations = await executor.invocations
        XCTAssertTrue(snapshot.dockerSocketAvailable)
        XCTAssertFalse(snapshot.refreshStatus.containersSucceeded)
        XCTAssertFalse(snapshot.refreshStatus.imagesSucceeded)
        XCTAssertFalse(snapshot.refreshStatus.volumesSucceeded)
        XCTAssertFalse(snapshot.refreshStatus.dockerNetworksSucceeded)
        XCTAssertFalse(snapshot.refreshStatus.statsSucceeded)
        XCTAssertFalse(snapshot.refreshStatus.processesSucceeded)
        XCTAssertTrue(snapshot.containers.isEmpty)
        XCTAssertTrue(snapshot.images.isEmpty)
        XCTAssertTrue(snapshot.volumes.isEmpty)
        XCTAssertTrue(snapshot.dockerNetworks.isEmpty)
        XCTAssertFalse(invocations.contains { $0.arguments.contains("ps") })
        XCTAssertFalse(invocations.contains { $0.arguments.contains("images") })
        XCTAssertFalse(invocations.contains { $0.arguments.contains("volume") && $0.arguments.contains("ls") })
        XCTAssertFalse(invocations.contains { $0.arguments.contains("network") && $0.arguments.contains("ls") })
        XCTAssertFalse(invocations.contains { $0.arguments.contains("stats") })
        XCTAssertFalse(invocations.contains { $0.arguments.contains("top") })
    }

    func testLoadSnapshotDetailedScopeRunsActivityProbes() async throws {
        let paths = try Self.makeTemporaryConjetPaths()
        try paths.ensureBaseDirectories()
        FileManager.default.createFile(atPath: paths.dockerSocket.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }

        let executor = RecordingCommandExecutor { invocation in
            Self.stubbedSnapshotResult(for: invocation, imageOutput: "", containerOutput: """
            {"ID":"api","Names":"api","Image":"alpine:3.20","Command":"\\"sleep 60\\"","CreatedAt":"2026-06-15 10:00:00 +0800 PST","RunningFor":"2 minutes","Ports":"","State":"running","Status":"Up 2 minutes","Size":"0B","Labels":""}
            """)
        }
        let service = Self.makeService(paths: paths, executor: executor)

        let snapshot = await service.loadSnapshot(scope: .detailed)

        let invocations = await executor.invocations
        XCTAssertTrue(snapshot.refreshStatus.statsSucceeded)
        XCTAssertTrue(snapshot.refreshStatus.processesSucceeded)
        XCTAssertTrue(invocations.contains { $0.arguments.contains("stats") })
        XCTAssertTrue(invocations.contains { $0.arguments.contains("top") })
        XCTAssertFalse(invocations.contains { $0.arguments.contains("system") && $0.arguments.contains("df") })
    }

    func testRunDockerFailsFastWhenConjetDockerSocketIsMissing() async throws {
        let paths = try Self.makeTemporaryConjetPaths()
        try paths.ensureBaseDirectories()
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }

        let executor = RecordingCommandExecutor { invocation in
            XCTFail("Docker should not be launched when the Conjet Docker socket is missing: \(invocation.arguments)")
            return Self.processResult(invocation, exitCode: 99)
        }
        let service = Self.makeService(paths: paths, executor: executor)

        let entry = await service.runDocker(["ps"], label: "Docker ps", timeoutSeconds: 120)

        XCTAssertFalse(entry.succeeded)
        XCTAssertEqual(entry.exitCode, 1)
        XCTAssertTrue(entry.stderr.contains("Conjet Docker socket is not available"))
        XCTAssertTrue(entry.stderr.contains(paths.rootHome.path))
        let invocations = await executor.invocations
        XCTAssertTrue(invocations.isEmpty)
    }

    func testRunComposeFailsFastWhenConjetDockerSocketIsMissing() async throws {
        let paths = try Self.makeTemporaryConjetPaths()
        try paths.ensureBaseDirectories()
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }

        let executor = RecordingCommandExecutor { invocation in
            XCTFail("Compose should not be launched when the Conjet Docker socket is missing: \(invocation.arguments)")
            return Self.processResult(invocation, exitCode: 99)
        }
        let service = Self.makeService(paths: paths, executor: executor)

        let entry = await service.runCompose(
            ["restart"],
            workingDirectory: paths.rootHome,
            label: "Compose Restart",
            timeoutSeconds: 600
        )

        XCTAssertFalse(entry.succeeded)
        XCTAssertEqual(entry.exitCode, 1)
        XCTAssertTrue(entry.stderr.contains("Conjet Docker socket is not available"))
        let invocations = await executor.invocations
        XCTAssertTrue(invocations.isEmpty)
    }

    func testLocalCommandExecutorCancelsRunningProcess() async throws {
        let executor = LocalCommandExecutor()
        let startedAt = Date()
        let task = Task {
            await executor.run(CommandInvocation(
                executable: "/bin/sh",
                arguments: ["-c", "trap '' TERM; while true; do :; done"],
                timeoutSeconds: nil
            ))
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let result = await task.value

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("process cancelled"))
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
    }

    private static func makeTemporaryConjetPaths() throws -> ConjetPaths {
        let home = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cj-ac-\(UUID().uuidString.prefix(8))", isDirectory: true)
        return ConjetPaths(home: home)
    }

    private static func makeService(
        paths: ConjetPaths,
        executor: RecordingCommandExecutor
    ) -> ConjetManagementService {
        let tool = ResolvedTool(executable: "/tmp/conjet-test-tool", source: "test")
        return ConjetManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path],
            conjetTool: tool,
            conjetCoreTool: tool,
            dockerTool: tool,
            includeLaunchdEnvironment: false,
            executor: executor
        )
    }

    private static func stubbedSnapshotResult(
        for invocation: CommandInvocation,
        imageOutput: String,
        containerOutput: String = ""
    ) -> ProcessResult {
        let arguments = invocation.arguments
        if arguments.contains("status"), arguments.contains("--json") {
            return processResult(
                invocation,
                stdout: #"{"ok":false,"message":"conjetd pid 123 is running but not answering at /tmp/conjetd.sock"}"#
            )
        }
        if arguments.starts(with: ["profile", "list", "--json"]) {
            return processResult(invocation, stdout: #"["default"]"#)
        }
        if arguments.contains("ps") {
            return processResult(invocation, stdout: containerOutput)
        }
        if arguments.contains("images") {
            return processResult(invocation, stdout: imageOutput)
        }
        if arguments.contains("volume"), arguments.contains("ls") {
            return processResult(invocation, stdout: "")
        }
        if arguments.contains("network"), arguments.contains("ls") {
            return processResult(invocation, stdout: #"{"ID":"bridge-id","Name":"bridge","Driver":"bridge","Scope":"local","IPv6":"false","Internal":"false","Labels":""}"#)
        }
        if arguments.contains("system"), arguments.contains("df") {
            return processResult(invocation, stdout: #"{"Volumes":[]}"#)
        }
        if arguments.contains("stats") {
            return processResult(invocation, stdout: "")
        }
        return processResult(invocation, stdout: "")
    }

    private static func processResult(
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

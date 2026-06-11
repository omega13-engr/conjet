import ConjetAppCore
import XCTest

final class ConjetAppCoreTests: XCTestCase {
    func testDecodesDockerContainerJSONLines() {
        let output = """
        {"ID":"abcdef123456","Names":"api","Image":"ubuntu:24.04","Command":"\\"sleep 60\\"","CreatedAt":"2026-06-11 08:00:00 +0800 PST","RunningFor":"2 minutes","Ports":"127.0.0.1:8080->80/tcp","State":"running","Status":"Up 2 minutes","Size":"0B"}
        {"ID":"fedcba654321","Names":"worker","Image":"alpine:3.20","Command":"\\"sh\\"","CreatedAt":"2026-06-11 08:01:00 +0800 PST","RunningFor":"1 minute","Ports":"","State":"exited","Status":"Exited (0)","Size":"0B"}
        """

        let containers = DockerJSONLines.decode(DockerContainer.self, from: output)

        XCTAssertEqual(containers.count, 2)
        XCTAssertEqual(containers[0].id, "abcdef123456")
        XCTAssertEqual(containers[0].name, "api")
        XCTAssertEqual(containers[0].state, "running")
        XCTAssertEqual(containers[1].image, "alpine:3.20")
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
        let invocation = tool.invocation(arguments: ["ps"], displayName: "Docker PS")

        XCTAssertEqual(invocation.executable, "/usr/bin/env")
        XCTAssertEqual(invocation.arguments, ["docker", "ps"])
        XCTAssertEqual(invocation.displayName, "Docker PS")
    }
}

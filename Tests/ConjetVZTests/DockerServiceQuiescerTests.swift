import ConjetCore
@testable import ConjetVZ
import XCTest

final class DockerServiceQuiescerTests: XCTestCase {
    func testQuiesceRunsPrivilegedNsenterAgainstConjetDockerSocket() throws {
        let socket = temporarySocketPath()
        FileManager.default.createFile(atPath: socket, contents: Data())

        var calls: [[String]] = []
        let quiescer = DockerServiceQuiescer(socketPath: socket) { executable, arguments, _ in
            calls.append([executable] + arguments)
            return ProcessResult(
                executable: executable,
                arguments: arguments,
                exitCode: calls.count == 1 ? 0 : 1,
                stdout: calls.count == 1 ? "" : "Cannot connect to the Docker daemon",
                stderr: ""
            )
        }

        try quiescer.quiesceForVMStop(timeoutSeconds: 2)

        XCTAssertGreaterThanOrEqual(calls.count, 2)
        XCTAssertTrue(calls[0].contains("--host"))
        XCTAssertTrue(calls[0].contains("unix://\(socket)"))
        XCTAssertTrue(calls[0].contains("--privileged"))
        XCTAssertTrue(calls[0].contains("nsenter"))
        XCTAssertTrue(calls[0].joined(separator: " ").contains("systemd-run"))
        XCTAssertTrue(calls[0].joined(separator: " ").contains("repair_stale_metadata"))
        XCTAssertTrue(calls[0].joined(separator: " ").contains("backed-up-and-removed-stale-docker-metadata"))
        XCTAssertTrue(calls[0].joined(separator: " ").contains("systemctl stop docker.socket docker.service containerd.service"))
        XCTAssertEqual(calls[1], ["/usr/bin/env", "docker", "--host", "unix://\(socket)", "info"])
    }

    func testQuiesceAcceptsDockerConnectionLossDuringShutdown() throws {
        let socket = temporarySocketPath()
        FileManager.default.createFile(atPath: socket, contents: Data())

        let quiescer = DockerServiceQuiescer(socketPath: socket) { executable, arguments, _ in
            ProcessResult(
                executable: executable,
                arguments: arguments,
                exitCode: 1,
                stdout: "",
                stderr: "error during connect: connection reset by peer"
            )
        }

        XCTAssertNoThrow(try quiescer.quiesceForVMStop(timeoutSeconds: 2))
    }

    func testQuiesceSkipsWhenSocketIsMissing() throws {
        var called = false
        let quiescer = DockerServiceQuiescer(socketPath: temporarySocketPath()) { _, _, _ in
            called = true
            return ProcessResult(executable: "", arguments: [], exitCode: 0, stdout: "", stderr: "")
        }

        try quiescer.quiesceForVMStop(timeoutSeconds: 2)

        XCTAssertFalse(called)
    }

    func testMemorySetupRunsGuestZramAndSwapBootstrap() throws {
        let socket = temporarySocketPath()
        FileManager.default.createFile(atPath: socket, contents: Data())

        var calls: [[String]] = []
        let quiescer = DockerServiceQuiescer(socketPath: socket) { executable, arguments, _ in
            calls.append([executable] + arguments)
            return ProcessResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                stdout: "guest memory setup: zram=enabled disk_swap=enabled\n",
                stderr: ""
            )
        }

        let output = try quiescer.ensureGuestMemorySetup(timeoutSeconds: 2)

        XCTAssertEqual(output, "guest memory setup: zram=enabled disk_swap=enabled")
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls[0].contains("--privileged"))
        XCTAssertTrue(calls[0].contains("--pull"))
        XCTAssertTrue(calls[0].contains("missing"))
        XCTAssertTrue(calls[0].contains("nsenter"))
        XCTAssertTrue(calls[0].joined(separator: " ").contains("modprobe zram"))
        XCTAssertTrue(calls[0].joined(separator: " ").contains("virtio-conjet-swap"))
        XCTAssertTrue(calls[0].joined(separator: " ").contains("virtio-conjet-blk2"))
        XCTAssertTrue(calls[0].joined(separator: " ").contains("/dev/vdc"))
        XCTAssertTrue(calls[0].joined(separator: " ").contains("swapon -p 1"))
    }

    func testMemorySetupReportsHelperPullOrRunFailure() throws {
        let socket = temporarySocketPath()
        FileManager.default.createFile(atPath: socket, contents: Data())

        var calls: [[String]] = []
        let quiescer = DockerServiceQuiescer(socketPath: socket) { executable, arguments, _ in
            calls.append([executable] + arguments)
            return ProcessResult(
                executable: executable,
                arguments: arguments,
                exitCode: 1,
                stdout: "",
                stderr: "No such image: ubuntu:24.04"
            )
        }

        let output = try quiescer.ensureGuestMemorySetup(timeoutSeconds: 2)

        XCTAssertEqual(output, "guest memory setup skipped: No such image: ubuntu:24.04")
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls[0].contains("run"))
        XCTAssertTrue(calls[0].contains("--pull"))
        XCTAssertTrue(calls[0].contains("missing"))
    }

    private func temporarySocketPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
    }
}

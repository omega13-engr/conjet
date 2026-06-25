import ConjetCore
import ConjetVZ
import XCTest

final class DockerRunExecutorTests: XCTestCase {
    func testMissingSocketDoesNotFallBackToHostDocker() throws {
        let socket = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("missing-conjet-docker-\(UUID().uuidString).sock")
        let result = try DockerRunExecutor(socketPath: socket.path).run(image: "hello-world", command: [])
        XCTAssertNil(result.exitCode)
        XCTAssertTrue(result.dockerHost.contains(socket.path))
        XCTAssertTrue(result.stderrTail.contains("Conjet Docker socket is not available"))
    }

    func testRunUsesConjetDockerHost() throws {
        let socket = try temporarySocketPlaceholder()
        let capture = DockerInvocationCapture()
        let result = try DockerRunExecutor(
            dockerCLIPath: "/bin/echo",
            socketPath: socket.path,
            runner: { executable, arguments in
                capture.record(executable: executable, arguments: arguments)
                return ProcessResult(
                    executable: executable,
                    arguments: arguments,
                    exitCode: 0,
                    stdout: "hello\n",
                    stderr: ""
                )
            }
        )
        .run(image: "alpine:3.20", command: ["echo", "hello"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdoutTail, "hello\n")
        XCTAssertEqual(capture.invocation?.executable, "/bin/echo")
        XCTAssertEqual(capture.invocation?.arguments, [
            "--host",
            "unix://\(socket.path)",
            "run",
            "--rm",
            "alpine:3.20",
            "echo",
            "hello"
        ])
    }

    func testRunPlacesAmd64PlatformBeforeImageWhenVZRosettaIsAvailable() throws {
        let socket = try temporarySocketPlaceholder()
        let capture = DockerInvocationCapture()
        let result = try DockerRunExecutor(
            dockerCLIPath: "/bin/echo",
            socketPath: socket.path,
            requestedBackend: .vz,
            rosettaAvailable: true,
            runner: { executable, arguments in
                capture.record(executable: executable, arguments: arguments)
                return ProcessResult(
                    executable: executable,
                    arguments: arguments,
                    exitCode: 0,
                    stdout: "amd64 ok\n",
                    stderr: ""
                )
            }
        )
        .run(image: "alpine:3.20", command: ["uname", "-m"], platform: "linux/amd64")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(capture.invocation?.arguments, [
            "--host",
            "unix://\(socket.path)",
            "run",
            "--rm",
            "--platform",
            "linux/amd64",
            "alpine:3.20",
            "uname",
            "-m"
        ])
    }

    func testRunRejectsAmd64OnHVFWithClearVZFallbackMessage() throws {
        let socket = try temporarySocketPlaceholder()
        let capture = DockerInvocationCapture()
        let result = try DockerRunExecutor(
            dockerCLIPath: "/bin/echo",
            socketPath: socket.path,
            requestedBackend: .hvfExperimental,
            rosettaAvailable: true,
            runner: { executable, arguments in
                capture.record(executable: executable, arguments: arguments)
                return ProcessResult(executable: executable, arguments: arguments, exitCode: 0, stdout: "", stderr: "")
            }
        )
        .run(image: "alpine:3.20", command: [], platform: "linux/amd64")

        XCTAssertNil(result.exitCode)
        XCTAssertNil(capture.invocation)
        XCTAssertTrue(result.stderrTail.contains("VZ fallback"))
        XCTAssertTrue(result.stderrTail.contains("linux/arm64"))
    }

    func testRunRejectsAmd64WhenRosettaIsUnavailable() throws {
        let socket = try temporarySocketPlaceholder()
        let result = try DockerRunExecutor(
            dockerCLIPath: "/bin/echo",
            socketPath: socket.path,
            requestedBackend: .vz,
            rosettaAvailable: false
        )
        .run(image: "alpine:3.20", command: [], platform: "linux/amd64")

        XCTAssertNil(result.exitCode)
        XCTAssertTrue(result.stderrTail.contains("Rosetta support was not detected"))
    }

    func testRunRejectsUnknownPlatformBeforeDockerInvocation() throws {
        let socket = try temporarySocketPlaceholder()
        let capture = DockerInvocationCapture()
        let result = try DockerRunExecutor(
            dockerCLIPath: "/bin/echo",
            socketPath: socket.path,
            requestedBackend: .vz,
            rosettaAvailable: true,
            runner: { executable, arguments in
                capture.record(executable: executable, arguments: arguments)
                return ProcessResult(executable: executable, arguments: arguments, exitCode: 0, stdout: "", stderr: "")
            }
        )
        .run(image: "alpine:3.20", command: [], platform: "linux/s390x")

        XCTAssertNil(result.exitCode)
        XCTAssertNil(capture.invocation)
        XCTAssertTrue(result.stderrTail.contains("container platform is unknown"))
    }

    func testComposeMissingSocketDoesNotFallBackToHostDocker() throws {
        let socket = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("missing-conjet-compose-\(UUID().uuidString).sock")
        let result = try DockerComposeExecutor(socketPath: socket.path).up(arguments: ["up", "--build"])

        XCTAssertNil(result.exitCode)
        XCTAssertTrue(result.dockerHost.contains(socket.path))
        XCTAssertEqual(result.executable, "")
        XCTAssertTrue(result.stderrTail.contains("Conjet Docker socket is not available"))
    }

    func testComposeUsesConjetDockerHost() throws {
        let socket = try temporarySocketPlaceholder()
        let capture = DockerInvocationCapture()
        let result = try DockerComposeExecutor(
            dockerCLIPath: "/bin/echo",
            socketPath: socket.path,
            runner: { executable, arguments in
                capture.record(executable: executable, arguments: arguments)
                return ProcessResult(
                    executable: executable,
                    arguments: arguments,
                    exitCode: 0,
                    stdout: "compose ok\n",
                    stderr: ""
                )
            }
        )
        .up(arguments: ["up", "--build"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdoutTail, "compose ok\n")
        XCTAssertEqual(result.executable, "/bin/echo")
        XCTAssertEqual(result.invocationKind, .dockerPlugin)
        XCTAssertEqual(capture.invocation?.arguments, [
            "--host",
            "unix://\(socket.path)",
            "compose",
            "up",
            "--build"
        ])
    }

    func testComposeAllowsGlobalOptionsBeforeUpCommand() throws {
        let socket = try temporarySocketPlaceholder()
        let capture = DockerInvocationCapture()
        let result = try DockerComposeExecutor(
            dockerCLIPath: "/bin/echo",
            socketPath: socket.path,
            runner: { executable, arguments in
                capture.record(executable: executable, arguments: arguments)
                return ProcessResult(
                    executable: executable,
                    arguments: arguments,
                    exitCode: 0,
                    stdout: "compose ok\n",
                    stderr: ""
                )
            }
        )
        .up(arguments: [
            "--project-directory", "/repo/app",
            "-f", "/repo/app/docker-compose.yml",
            "up",
            "--build",
            "-d"
        ])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(capture.invocation?.arguments, [
            "--host",
            "unix://\(socket.path)",
            "compose",
            "--project-directory", "/repo/app",
            "-f", "/repo/app/docker-compose.yml",
            "up",
            "--build",
            "-d"
        ])
    }

    func testComposeFallsBackToStandaloneComposeWhenDockerLacksComposePlugin() throws {
        let socket = try temporarySocketPlaceholder()
        let docker = try temporaryExecutable(named: "docker")
        let dockerCompose = try temporaryExecutable(named: "docker-compose")
        let invocationCapture = DockerInvocationCapture()
        let probeCapture = DockerComposeProbeCapture()
        let result = try DockerComposeExecutor(
            dockerCLIPath: docker.path,
            dockerComposeCLIPath: dockerCompose.path,
            socketPath: socket.path,
            composeSupportChecker: { path in
                probeCapture.record(path)
                return false
            },
            runner: { executable, arguments in
                invocationCapture.record(executable: executable, arguments: arguments)
                return ProcessResult(
                    executable: executable,
                    arguments: arguments,
                    exitCode: 0,
                    stdout: "compose ok\n",
                    stderr: ""
                )
            }
        )
        .up(arguments: ["up", "--build"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.executable, dockerCompose.path)
        XCTAssertEqual(result.invocationKind, .dockerCompose)
        XCTAssertEqual(probeCapture.paths, [docker.path])
        XCTAssertEqual(invocationCapture.invocation?.executable, dockerCompose.path)
        XCTAssertEqual(invocationCapture.invocation?.arguments, [
            "--host",
            "unix://\(socket.path)",
            "up",
            "--build"
        ])
    }

    func testComposeRejectsNonUpCommand() throws {
        XCTAssertThrowsError(try DockerComposeExecutor(socketPath: "/tmp/conjet.sock").up(arguments: ["down"])) { error in
            XCTAssertTrue(String(describing: error).contains("requires an 'up' command"))
        }
    }

    private func temporarySocketPlaceholder() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-docker-\(UUID().uuidString).sock")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func temporaryExecutable(named name: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-executable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return url
    }
}

private final class DockerInvocationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (executable: String, arguments: [String])?

    var invocation: (executable: String, arguments: [String])? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func record(executable: String, arguments: [String]) {
        lock.lock()
        defer { lock.unlock() }
        stored = (executable, arguments)
    }
}

private final class DockerComposeProbeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPaths: [String] = []

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedPaths
    }

    func record(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        storedPaths.append(path)
    }
}

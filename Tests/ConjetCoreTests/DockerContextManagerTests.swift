import ConjetCore
import XCTest

final class DockerContextManagerTests: XCTestCase {
    func testCreatesAndSelectsMissingContext() throws {
        let runner = FakeDockerContextRunner()
        runner.inspectHost = nil

        let result = try DockerContextManager(runner: runner.run)
            .ensureContext(socketPath: "/tmp/conjet/docker.sock")

        XCTAssertEqual(result.contextName, "conjet")
        XCTAssertEqual(result.dockerHost, "unix:///tmp/conjet/docker.sock")
        XCTAssertEqual(result.action, .created)
        XCTAssertTrue(result.madeCurrent)
        XCTAssertEqual(runner.inspectHost, "unix:///tmp/conjet/docker.sock")
        XCTAssertEqual(runner.currentContext, "conjet")
        XCTAssertTrue(runner.commands.contains(["docker", "context", "create", "conjet", "--description", "Conjet", "--docker", "host=unix:///tmp/conjet/docker.sock"]))
    }

    func testUpdatesMismatchedContext() throws {
        let runner = FakeDockerContextRunner()
        runner.inspectHost = "unix:///tmp/old.sock"

        let result = try DockerContextManager(runner: runner.run)
            .ensureContext(socketPath: "/tmp/conjet/docker.sock")

        XCTAssertEqual(result.action, .updated)
        XCTAssertEqual(runner.inspectHost, "unix:///tmp/conjet/docker.sock")
        XCTAssertEqual(runner.currentContext, "conjet")
        XCTAssertTrue(runner.commands.contains(["docker", "context", "update", "conjet", "--description", "Conjet", "--docker", "host=unix:///tmp/conjet/docker.sock"]))
    }

    func testSelectsExistingMatchingContext() throws {
        let runner = FakeDockerContextRunner()
        runner.inspectHost = "unix:///tmp/conjet/docker.sock"

        let result = try DockerContextManager(runner: runner.run)
            .ensureContext(socketPath: "/tmp/conjet/docker.sock")

        XCTAssertEqual(result.action, .unchanged)
        XCTAssertEqual(runner.currentContext, "conjet")
        XCTAssertFalse(runner.commands.contains { $0.contains("create") })
        XCTAssertFalse(runner.commands.contains { $0.contains("update") })
    }
}

private final class FakeDockerContextRunner {
    var inspectHost: String?
    var currentContext: String?
    var commands: [[String]] = []

    func run(executable: String, arguments: [String]) throws -> ProcessResult {
        commands.append(arguments)
        guard arguments.count >= 2, arguments[0] == "docker", arguments[1] == "context" else {
            return result(executable: executable, arguments: arguments, exitCode: 1, stderr: "unexpected command")
        }

        switch arguments[safe: 2] {
        case "inspect":
            guard let inspectHost else {
                return result(executable: executable, arguments: arguments, exitCode: 1, stderr: "context not found")
            }
            return result(executable: executable, arguments: arguments, stdout: "\"\(inspectHost)\"\n")
        case "create", "update":
            guard let dockerIndex = arguments.firstIndex(of: "--docker"),
                  arguments.indices.contains(dockerIndex + 1),
                  arguments[dockerIndex + 1].hasPrefix("host=") else {
                return result(executable: executable, arguments: arguments, exitCode: 1, stderr: "missing host")
            }
            inspectHost = String(arguments[dockerIndex + 1].dropFirst("host=".count))
            return result(executable: executable, arguments: arguments)
        case "use":
            currentContext = arguments[safe: 3]
            return result(executable: executable, arguments: arguments)
        default:
            return result(executable: executable, arguments: arguments, exitCode: 1, stderr: "unexpected context command")
        }
    }

    private func result(
        executable: String,
        arguments: [String],
        exitCode: Int32 = 0,
        stdout: String = "",
        stderr: String = ""
    ) -> ProcessResult {
        ProcessResult(
            executable: executable,
            arguments: arguments,
            exitCode: exitCode,
            stdout: stdout,
            stderr: stderr
        )
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

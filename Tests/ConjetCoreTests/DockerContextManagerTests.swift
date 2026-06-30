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
        XCTAssertEqual(result.buildxBuilderName, "conjet")
        XCTAssertEqual(result.buildxBuilderAction, .unchanged)
        XCTAssertEqual(runner.inspectHost, "unix:///tmp/conjet/docker.sock")
        XCTAssertEqual(runner.currentContext, "conjet")
        XCTAssertEqual(runner.currentBuilder, "conjet")
        XCTAssertTrue(runner.commands.contains(["docker", "context", "create", "conjet", "--description", "Conjet", "--docker", "host=unix:///tmp/conjet/docker.sock"]))
        XCTAssertTrue(runner.commands.contains(["docker", "buildx", "version"]))
        XCTAssertTrue(runner.commands.contains(["docker", "buildx", "inspect", "conjet", "--timeout", "2s"]))
        XCTAssertTrue(runner.commands.contains(["docker", "buildx", "use", "--default", "conjet"]))
        XCTAssertFalse(runner.commands.contains { $0.prefix(3).elementsEqual(["docker", "buildx", "create"]) })
    }

    func testUpdatesMismatchedContext() throws {
        let runner = FakeDockerContextRunner()
        runner.inspectHost = "unix:///tmp/old.sock"

        let result = try DockerContextManager(runner: runner.run)
            .ensureContext(socketPath: "/tmp/conjet/docker.sock")

        XCTAssertEqual(result.action, .updated)
        XCTAssertEqual(result.buildxBuilderName, "conjet")
        XCTAssertEqual(result.buildxBuilderAction, .unchanged)
        XCTAssertEqual(runner.inspectHost, "unix:///tmp/conjet/docker.sock")
        XCTAssertEqual(runner.currentContext, "conjet")
        XCTAssertEqual(runner.currentBuilder, "conjet")
        XCTAssertTrue(runner.commands.contains(["docker", "context", "update", "conjet", "--description", "Conjet", "--docker", "host=unix:///tmp/conjet/docker.sock"]))
    }

    func testSelectsExistingMatchingContext() throws {
        let runner = FakeDockerContextRunner()
        runner.inspectHost = "unix:///tmp/conjet/docker.sock"

        let result = try DockerContextManager(runner: runner.run)
            .ensureContext(socketPath: "/tmp/conjet/docker.sock")

        XCTAssertEqual(result.action, .unchanged)
        XCTAssertEqual(result.buildxBuilderName, "conjet")
        XCTAssertEqual(result.buildxBuilderAction, .unchanged)
        XCTAssertEqual(runner.currentContext, "conjet")
        XCTAssertEqual(runner.currentBuilder, "conjet")
        XCTAssertFalse(runner.commands.contains { $0.prefix(3).elementsEqual(["docker", "context", "create"]) })
        XCTAssertFalse(runner.commands.contains { $0.prefix(3).elementsEqual(["docker", "context", "update"]) })
    }

    func testRejectsMismatchedContextBuildxBuilder() throws {
        let runner = FakeDockerContextRunner()
        runner.inspectHost = "unix:///tmp/conjet/docker.sock"
        runner.contextBuilder = .init(driver: "docker-container", endpoint: "conjet")

        XCTAssertThrowsError(
            try DockerContextManager(runner: runner.run)
                .ensureContext(socketPath: "/tmp/conjet/docker.sock")
        )
        XCTAssertNil(runner.currentBuilder)
        XCTAssertFalse(runner.commands.contains { $0.prefix(3).elementsEqual(["docker", "buildx", "create"]) })
        XCTAssertFalse(runner.commands.contains { $0.prefix(3).elementsEqual(["docker", "buildx", "rm"]) })
    }

    func testCanSkipBuildxBuilderConfiguration() throws {
        let runner = FakeDockerContextRunner()
        runner.inspectHost = "unix:///tmp/conjet/docker.sock"

        let result = try DockerContextManager(runner: runner.run)
            .ensureContext(socketPath: "/tmp/conjet/docker.sock", configureBuildxBuilder: false)

        XCTAssertNil(result.buildxBuilderName)
        XCTAssertNil(result.buildxBuilderAction)
        XCTAssertFalse(runner.commands.contains { $0.contains("buildx") })
    }

    func testMakeCurrentFalseDoesNotSelectContextOrBuilder() throws {
        let runner = FakeDockerContextRunner()
        runner.inspectHost = "unix:///tmp/conjet/docker.sock"

        let result = try DockerContextManager(runner: runner.run)
            .ensureContext(socketPath: "/tmp/conjet/docker.sock", makeCurrent: false)

        XCTAssertFalse(result.madeCurrent)
        XCTAssertEqual(result.buildxBuilderName, "conjet")
        XCTAssertEqual(result.buildxBuilderAction, .unchanged)
        XCTAssertNil(runner.currentContext)
        XCTAssertNil(runner.currentBuilder)
        XCTAssertTrue(runner.commands.contains(["docker", "buildx", "version"]))
        XCTAssertTrue(runner.commands.contains(["docker", "buildx", "inspect", "conjet", "--timeout", "2s"]))
        XCTAssertFalse(runner.commands.contains(["docker", "buildx", "use", "--default", "conjet"]))
    }

    func testKeepsDockerContextWhenBuildxPluginIsUnavailable() throws {
        let runner = FakeDockerContextRunner()
        runner.inspectHost = nil
        runner.buildxAvailable = false

        let result = try DockerContextManager(runner: runner.run)
            .ensureContext(socketPath: "/tmp/conjet/docker.sock")

        XCTAssertEqual(result.contextName, "conjet")
        XCTAssertEqual(result.dockerHost, "unix:///tmp/conjet/docker.sock")
        XCTAssertEqual(result.action, .created)
        XCTAssertTrue(result.madeCurrent)
        XCTAssertNil(result.buildxBuilderName)
        XCTAssertNil(result.buildxBuilderAction)
        XCTAssertEqual(runner.inspectHost, "unix:///tmp/conjet/docker.sock")
        XCTAssertEqual(runner.currentContext, "conjet")
        XCTAssertNil(runner.currentBuilder)
        XCTAssertTrue(runner.commands.contains(["docker", "buildx", "version"]))
        XCTAssertFalse(runner.commands.contains(["docker", "buildx", "inspect", "conjet", "--timeout", "2s"]))
    }
}

private final class FakeDockerContextRunner {
    struct Builder {
        var driver: String
        var endpoint: String
    }

    var inspectHost: String?
    var currentContext: String?
    var currentBuilder: String?
    var buildxAvailable = true
    var contextBuilder = Builder(driver: "docker", endpoint: "conjet")
    var commands: [[String]] = []

    func run(executable: String, arguments: [String]) throws -> ProcessResult {
        commands.append(arguments)
        guard arguments.count >= 2, arguments[0] == "docker" else {
            return result(executable: executable, arguments: arguments, exitCode: 1, stderr: "unexpected command")
        }

        if arguments[1] == "buildx" {
            return runBuildx(executable: executable, arguments: arguments)
        }

        guard arguments[1] == "context" else {
            return result(executable: executable, arguments: arguments, exitCode: 1, stderr: "unexpected docker command")
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

    private func runBuildx(executable: String, arguments: [String]) -> ProcessResult {
        guard buildxAvailable else {
            return result(executable: executable, arguments: arguments, exitCode: 1, stderr: "docker: unknown command: docker buildx")
        }

        switch arguments[safe: 2] {
        case "version":
            return result(executable: executable, arguments: arguments, stdout: "github.com/docker/buildx v0.35.0\n")
        case "inspect":
            guard let name = arguments[safe: 3],
                  name == "conjet",
                  inspectHost != nil else {
                return result(executable: executable, arguments: arguments, exitCode: 1, stderr: "builder not found")
            }
            let builder = contextBuilder
            return result(executable: executable, arguments: arguments, stdout: """
            Name:   \(name)
            Driver: \(builder.driver)

            Nodes:
            Name:     \(name)
            Endpoint: \(builder.endpoint)

            """)
        case "use":
            guard let name = arguments.last, name == "conjet", inspectHost != nil else {
                return result(executable: executable, arguments: arguments, exitCode: 1, stderr: "builder not found")
            }
            currentBuilder = name
            return result(executable: executable, arguments: arguments)
        default:
            return result(executable: executable, arguments: arguments, exitCode: 1, stderr: "unexpected buildx command")
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

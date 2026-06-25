import ConjetCore
import XCTest

final class DockerContextManagerTests: XCTestCase {
    func testCreatesAndSelectsMissingContext() throws {
        let runner = FakeDockerContextRunner()
        runner.inspectHost = nil

        let result = try manager(runner: runner)
            .ensureContext(socketPath: "/tmp/conjet/docker.sock")

        XCTAssertEqual(result.contextName, "conjet")
        XCTAssertEqual(result.dockerHost, "unix:///tmp/conjet/docker.sock")
        XCTAssertEqual(result.action, .created)
        XCTAssertTrue(result.madeCurrent)
        XCTAssertEqual(result.buildxBuilderName, "conjet-buildkit")
        XCTAssertEqual(result.buildxBuilderAction, .created)
        XCTAssertEqual(runner.inspectHost, "unix:///tmp/conjet/docker.sock")
        XCTAssertEqual(runner.currentContext, "conjet")
        XCTAssertEqual(runner.currentBuilder, "conjet-buildkit")
        XCTAssertTrue(runner.commands.contains(["docker", "context", "create", "conjet", "--description", "Conjet", "--docker", "host=unix:///tmp/conjet/docker.sock"]))
        XCTAssertTrue(runner.commands.contains(["docker", "buildx", "inspect", "conjet-buildkit", "--timeout", "2s"]))
        XCTAssertTrue(runner.commands.contains { command in
            command.prefix(6).elementsEqual(["docker", "buildx", "create", "--name", "conjet-buildkit", "--driver"])
                && command.contains("docker-container")
                && command.contains("--buildkitd-config")
                && command.contains("--bootstrap")
                && command.contains("--use")
                && command.last == "conjet"
        })
        XCTAssertTrue(runner.commands.contains(["docker", "buildx", "use", "--default", "conjet-buildkit"]))
    }

    func testUpdatesMismatchedContext() throws {
        let runner = FakeDockerContextRunner()
        runner.inspectHost = "unix:///tmp/old.sock"

        let result = try manager(runner: runner)
            .ensureContext(socketPath: "/tmp/conjet/docker.sock")

        XCTAssertEqual(result.action, .updated)
        XCTAssertEqual(result.buildxBuilderName, "conjet-buildkit")
        XCTAssertEqual(result.buildxBuilderAction, .created)
        XCTAssertEqual(runner.inspectHost, "unix:///tmp/conjet/docker.sock")
        XCTAssertEqual(runner.currentContext, "conjet")
        XCTAssertEqual(runner.currentBuilder, "conjet-buildkit")
        XCTAssertTrue(runner.commands.contains(["docker", "context", "update", "conjet", "--description", "Conjet", "--docker", "host=unix:///tmp/conjet/docker.sock"]))
    }

    func testSelectsExistingMatchingContext() throws {
        let runner = FakeDockerContextRunner()
        runner.inspectHost = "unix:///tmp/conjet/docker.sock"
        runner.contextBuilder = .init(driver: "docker-container", endpoint: "conjet", maxParallelism: 1)

        let result = try manager(runner: runner)
            .ensureContext(socketPath: "/tmp/conjet/docker.sock")

        XCTAssertEqual(result.action, .unchanged)
        XCTAssertEqual(result.buildxBuilderName, "conjet-buildkit")
        XCTAssertEqual(result.buildxBuilderAction, .unchanged)
        XCTAssertEqual(runner.currentContext, "conjet")
        XCTAssertEqual(runner.currentBuilder, "conjet-buildkit")
        XCTAssertFalse(runner.commands.contains { $0.prefix(3).elementsEqual(["docker", "context", "create"]) })
        XCTAssertFalse(runner.commands.contains { $0.prefix(3).elementsEqual(["docker", "context", "update"]) })
        XCTAssertFalse(runner.commands.contains { $0.prefix(3).elementsEqual(["docker", "buildx", "create"]) })
    }

    func testReplacesExistingDockerContainerBuilderWithStaleBuildKitConfig() throws {
        let runner = FakeDockerContextRunner()
        runner.inspectHost = "unix:///tmp/conjet/docker.sock"
        runner.contextBuilder = .init(driver: "docker-container", endpoint: "conjet", maxParallelism: 2)

        let result = try manager(runner: runner)
            .ensureContext(socketPath: "/tmp/conjet/docker.sock")

        XCTAssertEqual(result.buildxBuilderAction, .updated)
        XCTAssertEqual(runner.contextBuilder?.driver, "docker-container")
        XCTAssertEqual(runner.contextBuilder?.maxParallelism, 1)
        XCTAssertTrue(runner.commands.contains(["docker", "buildx", "rm", "--force", "conjet-buildkit"]))
        XCTAssertTrue(runner.commands.contains { $0.prefix(3).elementsEqual(["docker", "buildx", "create"]) })
    }

    func testReplacesExistingDockerDriverBuilder() throws {
        let runner = FakeDockerContextRunner()
        runner.inspectHost = "unix:///tmp/conjet/docker.sock"
        runner.contextBuilder = .init(driver: "docker", endpoint: "conjet", maxParallelism: nil)

        let result = try manager(runner: runner)
            .ensureContext(socketPath: "/tmp/conjet/docker.sock")

        XCTAssertEqual(result.buildxBuilderAction, .updated)
        XCTAssertEqual(runner.contextBuilder?.driver, "docker-container")
        XCTAssertTrue(runner.commands.contains(["docker", "buildx", "rm", "--force", "conjet-buildkit"]))
        XCTAssertTrue(runner.commands.contains { $0.prefix(3).elementsEqual(["docker", "buildx", "create"]) })
    }

    func testRejectsMismatchedContextBuildxBuilder() throws {
        let runner = FakeDockerContextRunner()
        runner.inspectHost = "unix:///tmp/conjet/docker.sock"
        runner.contextBuilder = .init(driver: "docker-container", endpoint: "other", maxParallelism: 1)

        XCTAssertThrowsError(
            try manager(runner: runner)
                .ensureContext(socketPath: "/tmp/conjet/docker.sock")
        )
        XCTAssertNil(runner.currentBuilder)
        XCTAssertFalse(runner.commands.contains { $0.prefix(3).elementsEqual(["docker", "buildx", "create"]) })
        XCTAssertFalse(runner.commands.contains { $0.prefix(3).elementsEqual(["docker", "buildx", "rm"]) })
    }

    func testCanSkipBuildxBuilderConfiguration() throws {
        let runner = FakeDockerContextRunner()
        runner.inspectHost = "unix:///tmp/conjet/docker.sock"

        let result = try manager(runner: runner)
            .ensureContext(socketPath: "/tmp/conjet/docker.sock", configureBuildxBuilder: false)

        XCTAssertNil(result.buildxBuilderName)
        XCTAssertNil(result.buildxBuilderAction)
        XCTAssertFalse(runner.commands.contains { $0.contains("buildx") })
    }

    func testMakeCurrentFalseDoesNotSelectContextOrBuilder() throws {
        let runner = FakeDockerContextRunner()
        runner.inspectHost = "unix:///tmp/conjet/docker.sock"

        let result = try manager(runner: runner)
            .ensureContext(socketPath: "/tmp/conjet/docker.sock", makeCurrent: false)

        XCTAssertFalse(result.madeCurrent)
        XCTAssertEqual(result.buildxBuilderName, "conjet-buildkit")
        XCTAssertEqual(result.buildxBuilderAction, .created)
        XCTAssertNil(runner.currentContext)
        XCTAssertNil(runner.currentBuilder)
        XCTAssertTrue(runner.commands.contains(["docker", "buildx", "inspect", "conjet-buildkit", "--timeout", "2s"]))
        XCTAssertFalse(runner.commands.contains(["docker", "buildx", "use", "--default", "conjet-buildkit"]))
        XCTAssertTrue(runner.commands.contains { command in
            command.prefix(3).elementsEqual(["docker", "buildx", "create"])
                && !command.contains("--use")
        })
    }

    func testDefaultBuildKitMaxParallelismCanBeOverriddenByEnvironment() {
        XCTAssertEqual(DockerContextManager.defaultBuildKitMaxParallelism(environment: [:]), 1)
        XCTAssertEqual(
            DockerContextManager.defaultBuildKitMaxParallelism(
                environment: ["CONJET_BUILDKIT_MAX_PARALLELISM": "3"]
            ),
            3
        )
        XCTAssertEqual(
            DockerContextManager.defaultBuildKitMaxParallelism(
                environment: ["CONJET_BUILDKIT_MAX_PARALLELISM": "0"]
            ),
            1
        )
    }

    private func manager(runner: FakeDockerContextRunner) -> DockerContextManager {
        DockerContextManager(
            buildkitConfigDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("conjet-buildkit-test-\(UUID().uuidString)", isDirectory: true),
            runner: runner.run
        )
    }
}

private final class FakeDockerContextRunner {
    struct Builder {
        var driver: String
        var endpoint: String
        var maxParallelism: Int?
    }

    var inspectHost: String?
    var currentContext: String?
    var currentBuilder: String?
    var contextBuilder: Builder?
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
        switch arguments[safe: 2] {
        case "inspect":
            guard let name = arguments[safe: 3],
                  name == "conjet-buildkit",
                  inspectHost != nil,
                  let contextBuilder else {
                return result(executable: executable, arguments: arguments, exitCode: 1, stderr: "builder not found")
            }
            let builder = contextBuilder
            let config = builder.maxParallelism.map { maxParallelism in
                """
                File#buildkitd.toml:
                 > [worker.oci]
                 > max-parallelism = \(maxParallelism)

                """
            } ?? ""
            return result(executable: executable, arguments: arguments, stdout: """
            Name:   \(name)
            Driver: \(builder.driver)

            Nodes:
            Name:     \(name)
            Endpoint: \(builder.endpoint)

            \(config)
            """)
        case "rm":
            let name = arguments.last
            guard name == "conjet-buildkit" else {
                return result(executable: executable, arguments: arguments, exitCode: 1, stderr: "builder not found")
            }
            contextBuilder = nil
            return result(executable: executable, arguments: arguments)
        case "create":
            guard let nameIndex = arguments.firstIndex(of: "--name"),
                  arguments.indices.contains(nameIndex + 1),
                  arguments[nameIndex + 1] == "conjet-buildkit",
                  let driverIndex = arguments.firstIndex(of: "--driver"),
                  arguments.indices.contains(driverIndex + 1),
                  arguments[driverIndex + 1] == "docker-container",
                  arguments.contains("--buildkitd-config"),
                  let endpoint = arguments.last,
                  endpoint == "conjet" else {
                return result(executable: executable, arguments: arguments, exitCode: 1, stderr: "invalid buildx create")
            }
            contextBuilder = Builder(driver: "docker-container", endpoint: endpoint, maxParallelism: 1)
            if arguments.contains("--use") {
                currentBuilder = "conjet-buildkit"
            }
            return result(executable: executable, arguments: arguments)
        case "use":
            guard let name = arguments.last, name == "conjet-buildkit", inspectHost != nil else {
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

import ConjetCore
import Foundation

public struct DockerBenchmarkSuite {
    public var contexts: [String]
    public var iterations: Int
    public var warmup: Bool
    public var dockerExecutable: String

    private let runner: (String, [String]) throws -> ProcessResult

    public init(
        contexts: [String],
        iterations: Int = 1,
        warmup: Bool = false,
        dockerExecutable: String = "/usr/bin/env",
        runner: @escaping (String, [String]) throws -> ProcessResult = ProcessRunner.run
    ) {
        self.contexts = contexts
        self.iterations = max(1, iterations)
        self.warmup = warmup
        self.dockerExecutable = dockerExecutable
        self.runner = runner
    }

    public func run(workDirectory: URL) throws -> [BenchmarkResult] {
        guard !contexts.isEmpty else {
            throw ConjetError.invalidArgument("at least one Docker context is required")
        }

        let workDirectory = workDirectory.standardizedFileURL
        let buildDirectory = workDirectory.appendingPathComponent("build-context", isDirectory: true)
        let composeDirectory = workDirectory.appendingPathComponent("compose", isDirectory: true)
        try prepareBuildContext(at: buildDirectory)
        let composeFile = try prepareComposeProject(at: composeDirectory)

        var results: [BenchmarkResult] = []
        for context in contexts {
            if warmup {
                _ = try? runDocker(context: context, arguments: ["pull", "alpine:3.20"])
                _ = try? runDocker(context: context, arguments: ["pull", "busybox:1.36"])
            }

            for iteration in 1...iterations {
                results.append(try benchmark(
                    workload: "docker-version",
                    context: context,
                    iteration: iteration,
                    arguments: ["version", "--format", "{{.Server.Version}}"]
                ))
                results.append(try benchmark(
                    workload: "container-start",
                    context: context,
                    iteration: iteration,
                    arguments: ["run", "--rm", "alpine:3.20", "true"]
                ))
                let imageTag = "conjet-bench-\(context.sanitizedDockerTag)-\(iteration)"
                results.append(try benchmark(
                    workload: "image-build",
                    context: context,
                    iteration: iteration,
                    arguments: ["build", "-t", imageTag, buildDirectory.path]
                ))
                _ = try? runDocker(context: context, arguments: ["rmi", "-f", imageTag])

                results.append(try benchmark(
                    workload: "compose-up",
                    context: context,
                    iteration: iteration,
                    arguments: [
                        "compose",
                        "-f",
                        composeFile.path,
                        "-p",
                        "conjet-bench-\(context.sanitizedDockerTag)-\(iteration)",
                        "up",
                        "--abort-on-container-exit",
                        "--exit-code-from",
                        "app",
                        "--remove-orphans"
                    ]
                ))
                _ = try? runDocker(context: context, arguments: [
                    "compose",
                    "-f",
                    composeFile.path,
                    "-p",
                    "conjet-bench-\(context.sanitizedDockerTag)-\(iteration)",
                    "down",
                    "-v",
                    "--remove-orphans"
                ])
            }
        }

        return results
    }

    private func benchmark(
        workload: String,
        context: String,
        iteration: Int,
        arguments: [String]
    ) throws -> BenchmarkResult {
        let command = dockerArguments(context: context, arguments: arguments)
        let machine = MachineProfiler.capture()
        let startedAt = Date()
        let result = try runner(dockerExecutable, command)
        let duration = Date().timeIntervalSince(startedAt)
        return BenchmarkResult(
            workload: workload,
            runtime: context,
            command: [dockerExecutable] + command,
            startedAt: startedAt,
            durationSeconds: duration,
            exitCode: result.exitCode,
            metrics: ["iteration": Double(iteration)],
            machine: machine,
            stdoutTail: tail(result.stdout),
            stderrTail: tail(result.stderr)
        )
    }

    private func runDocker(context: String, arguments: [String]) throws -> ProcessResult {
        try runner(dockerExecutable, dockerArguments(context: context, arguments: arguments))
    }

    private func dockerArguments(context: String, arguments: [String]) -> [String] {
        ["docker", "--context", context] + arguments
    }

    private func prepareBuildContext(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dockerfile = """
        FROM alpine:3.20
        RUN echo conjet-benchmark >/message
        CMD ["cat", "/message"]
        """
        try dockerfile.write(
            to: directory.appendingPathComponent("Dockerfile"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func prepareComposeProject(at directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let composeFile = directory.appendingPathComponent("compose.yaml")
        let compose = """
        services:
          app:
            image: busybox:1.36
            command: ["sh", "-c", "echo conjet-compose-app"]
          sidecar:
            image: busybox:1.36
            command: ["sh", "-c", "echo conjet-compose-sidecar"]
        """
        try compose.write(to: composeFile, atomically: true, encoding: .utf8)
        return composeFile
    }

    private func tail(_ text: String, limit: Int = 4096) -> String {
        if text.count <= limit { return text }
        return String(text.suffix(limit))
    }
}

private extension String {
    var sanitizedDockerTag: String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        let sanitized = String(map { allowed.contains($0) ? $0 : "-" })
        return sanitized.isEmpty ? "runtime" : sanitized.lowercased()
    }
}

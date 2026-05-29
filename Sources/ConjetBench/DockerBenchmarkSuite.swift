import ConjetCore
import Foundation

public struct DockerBenchmarkSuite {
    public static let defaultWorkloads = [
        "docker-version",
        "container-start",
        "image-build",
        "copy-node-modules",
        "npm-install",
        "cargo-build",
        "named-volume-io",
        "tmpfs-volume-io",
        "compose-up"
    ]

    public var contexts: [String]
    public var iterations: Int
    public var warmup: Bool
    public var dockerExecutable: String
    public var workloads: [String]

    private let runner: (String, [String]) throws -> ProcessResult

    public init(
        contexts: [String],
        iterations: Int = 1,
        warmup: Bool = false,
        workloads: [String] = DockerBenchmarkSuite.defaultWorkloads,
        dockerExecutable: String = "/usr/bin/env",
        runner: @escaping (String, [String]) throws -> ProcessResult = ProcessRunner.run
    ) {
        self.contexts = contexts
        self.iterations = max(1, iterations)
        self.warmup = warmup
        self.workloads = workloads.isEmpty ? DockerBenchmarkSuite.defaultWorkloads : workloads
        self.dockerExecutable = dockerExecutable
        self.runner = runner
    }

    public func run(workDirectory: URL) throws -> [BenchmarkResult] {
        guard !contexts.isEmpty else {
            throw ConjetError.invalidArgument("at least one Docker context is required")
        }
        let enabledWorkloads = Set(workloads)
        let unknownWorkloads = enabledWorkloads.subtracting(Self.defaultWorkloads)
        guard unknownWorkloads.isEmpty else {
            throw ConjetError.invalidArgument(
                "unknown Docker benchmark workloads: \(unknownWorkloads.sorted().joined(separator: ", "))"
            )
        }

        let workDirectory = workDirectory.standardizedFileURL
        let buildDirectory = workDirectory.appendingPathComponent("build-context", isDirectory: true)
        let nodeModulesCopyDirectory = workDirectory.appendingPathComponent("copy-node-modules", isDirectory: true)
        let npmInstallDirectory = workDirectory.appendingPathComponent("npm-install", isDirectory: true)
        let cargoBuildDirectory = workDirectory.appendingPathComponent("cargo-build", isDirectory: true)
        let composeDirectory = workDirectory.appendingPathComponent("compose", isDirectory: true)
        try prepareBuildContext(at: buildDirectory)
        let nodeModulesFileCount = try prepareNodeModulesCopyContext(at: nodeModulesCopyDirectory)
        try prepareNPMInstallContext(at: npmInstallDirectory)
        try prepareCargoBuildContext(at: cargoBuildDirectory)
        let composeFile = try prepareComposeProject(at: composeDirectory)

        var results: [BenchmarkResult] = []
        for context in contexts {
            if warmup {
                for image in warmupImages(for: enabledWorkloads) {
                    _ = try? runDocker(context: context, arguments: ["pull", image])
                }
            }

            for iteration in 1...iterations {
                if enabledWorkloads.contains("docker-version") {
                    results.append(try benchmark(
                        workload: "docker-version",
                        context: context,
                        iteration: iteration,
                        arguments: ["version", "--format", "{{.Server.Version}}"]
                    ))
                }

                if enabledWorkloads.contains("container-start") {
                    results.append(try benchmark(
                        workload: "container-start",
                        context: context,
                        iteration: iteration,
                        arguments: ["run", "--rm", "alpine:3.20", "true"]
                    ))
                }

                if enabledWorkloads.contains("image-build") {
                    let imageTag = "conjet-bench-\(context.sanitizedDockerTag)-image-\(iteration)"
                    results.append(try benchmark(
                        workload: "image-build",
                        context: context,
                        iteration: iteration,
                        arguments: ["build", "-t", imageTag, buildDirectory.path]
                    ))
                    _ = try? runDocker(context: context, arguments: ["rmi", "-f", imageTag])
                }

                if enabledWorkloads.contains("copy-node-modules") {
                    try updateNodeModulesCopyMarker(at: nodeModulesCopyDirectory, iteration: iteration)
                    let imageTag = "conjet-bench-\(context.sanitizedDockerTag)-copy-node-modules-\(iteration)"
                    results.append(try benchmark(
                        workload: "copy-node-modules",
                        context: context,
                        iteration: iteration,
                        arguments: ["build", "-t", imageTag, nodeModulesCopyDirectory.path],
                        metrics: ["file_count": Double(nodeModulesFileCount)]
                    ))
                    _ = try? runDocker(context: context, arguments: ["rmi", "-f", imageTag])
                }

                if enabledWorkloads.contains("npm-install") {
                    let imageTag = "conjet-bench-\(context.sanitizedDockerTag)-npm-\(iteration)"
                    results.append(try benchmark(
                        workload: "npm-install",
                        context: context,
                        iteration: iteration,
                        arguments: [
                            "build",
                            "--build-arg",
                            "CONJET_BENCH_ITERATION=\(iteration)",
                            "-t",
                            imageTag,
                            npmInstallDirectory.path
                        ],
                        metrics: ["dependency_count": 3]
                    ))
                    _ = try? runDocker(context: context, arguments: ["rmi", "-f", imageTag])
                }

                if enabledWorkloads.contains("cargo-build") {
                    let imageTag = "conjet-bench-\(context.sanitizedDockerTag)-cargo-\(iteration)"
                    results.append(try benchmark(
                        workload: "cargo-build",
                        context: context,
                        iteration: iteration,
                        arguments: [
                            "build",
                            "--build-arg",
                            "CONJET_BENCH_ITERATION=\(iteration)",
                            "-t",
                            imageTag,
                            cargoBuildDirectory.path
                        ],
                        metrics: ["dependency_count": 2]
                    ))
                    _ = try? runDocker(context: context, arguments: ["rmi", "-f", imageTag])
                }

                if enabledWorkloads.contains("named-volume-io") {
                    let volumeName = "conjet-bench-\(context.sanitizedDockerTag)-volume-\(iteration)"
                    _ = try? runDocker(context: context, arguments: ["volume", "rm", "-f", volumeName])
                    results.append(try benchmark(
                        workload: "named-volume-io",
                        context: context,
                        iteration: iteration,
                        arguments: [
                            "run",
                            "--rm",
                            "--mount",
                            "type=volume,source=\(volumeName),target=/data",
                            "busybox:1.36",
                            "sh",
                            "-c",
                            volumeWriteScript(directory: "/data")
                        ],
                        metrics: ["file_count": 300]
                    ))
                    _ = try? runDocker(context: context, arguments: ["volume", "rm", "-f", volumeName])
                }

                if enabledWorkloads.contains("tmpfs-volume-io") {
                    results.append(try benchmark(
                        workload: "tmpfs-volume-io",
                        context: context,
                        iteration: iteration,
                        arguments: [
                            "run",
                            "--rm",
                            "--tmpfs",
                            "/scratch:rw,size=64m",
                            "busybox:1.36",
                            "sh",
                            "-c",
                            volumeWriteScript(directory: "/scratch")
                        ],
                        metrics: ["file_count": 300]
                    ))
                }

                if enabledWorkloads.contains("compose-up") {
                    let project = "conjet-bench-\(context.sanitizedDockerTag)-\(iteration)"
                    results.append(try benchmark(
                        workload: "compose-up",
                        context: context,
                        iteration: iteration,
                        arguments: [
                            "compose",
                            "-f",
                            composeFile.path,
                            "-p",
                            project,
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
                        project,
                        "down",
                        "-v",
                        "--remove-orphans"
                    ])
                }
            }
        }

        return results
    }

    private func benchmark(
        workload: String,
        context: String,
        iteration: Int,
        arguments: [String],
        metrics: [String: Double] = [:]
    ) throws -> BenchmarkResult {
        let command = dockerArguments(context: context, arguments: arguments)
        let machine = MachineProfiler.capture()
        let startedAt = Date()
        let result = try runner(dockerExecutable, command)
        let duration = Date().timeIntervalSince(startedAt)
        var resultMetrics = metrics
        resultMetrics["iteration"] = Double(iteration)
        return BenchmarkResult(
            workload: workload,
            runtime: context,
            command: [dockerExecutable] + command,
            startedAt: startedAt,
            durationSeconds: duration,
            exitCode: result.exitCode,
            metrics: resultMetrics,
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

    private func prepareNodeModulesCopyContext(at directory: URL) throws -> Int {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let nodeModules = directory.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)

        var fileCount = 0
        for packageIndex in 0..<8 {
            let package = nodeModules.appendingPathComponent("conjet-package-\(packageIndex)", isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let packageJSON = #"{"name":"conjet-package-\#(packageIndex)","version":"1.0.0"}"#
            try packageJSON.write(
                to: package.appendingPathComponent("package.json"),
                atomically: true,
                encoding: .utf8
            )
            fileCount += 1

            for fileIndex in 0..<75 {
                let content = """
                module.exports = "\(packageIndex)-\(fileIndex)-conjet-node-modules-copy-benchmark";
                """
                try content.write(
                    to: package.appendingPathComponent("file-\(fileIndex).js"),
                    atomically: true,
                    encoding: .utf8
                )
                fileCount += 1
            }
        }
        try updateNodeModulesCopyMarker(at: directory, iteration: 0)
        fileCount += 1

        let dockerfile = """
        FROM alpine:3.20
        WORKDIR /app
        COPY node_modules ./node_modules
        RUN find node_modules -type f | wc -l >/node-modules-file-count
        CMD ["cat", "/node-modules-file-count"]
        """
        try dockerfile.write(
            to: directory.appendingPathComponent("Dockerfile"),
            atomically: true,
            encoding: .utf8
        )
        return fileCount
    }

    private func updateNodeModulesCopyMarker(at directory: URL, iteration: Int) throws {
        let marker = directory
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(".conjet-copy-marker")
        try "iteration=\(iteration)\n".write(to: marker, atomically: true, encoding: .utf8)
    }

    private func prepareNPMInstallContext(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let packageJSON = """
        {
          "name": "conjet-npm-install-benchmark",
          "version": "1.0.0",
          "private": true,
          "dependencies": {
            "is-number": "7.0.0",
            "lodash": "4.17.21",
            "nanoid": "5.0.7"
          }
        }
        """
        try packageJSON.write(
            to: directory.appendingPathComponent("package.json"),
            atomically: true,
            encoding: .utf8
        )

        let dockerfile = #"""
        # syntax=docker/dockerfile:1.7
        FROM node:22-alpine
        WORKDIR /app
        COPY package.json ./
        ARG CONJET_BENCH_ITERATION=0
        RUN --mount=type=cache,target=/root/.npm \
            echo "$CONJET_BENCH_ITERATION" >/tmp/conjet-bench-iteration \
            && npm install --prefer-offline --no-audit --no-fund \
            && node -e "const _ = require('lodash'); console.log(_.camelCase('conjet npm install benchmark'))"
        """#
        try dockerfile.write(
            to: directory.appendingPathComponent("Dockerfile"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func prepareCargoBuildContext(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceDirectory = directory.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        let cargoToml = """
        [package]
        name = "conjet-cargo-build-benchmark"
        version = "0.1.0"
        edition = "2021"

        [dependencies]
        itoa = "1.0.11"
        ryu = "1.0.18"
        """
        try cargoToml.write(
            to: directory.appendingPathComponent("Cargo.toml"),
            atomically: true,
            encoding: .utf8
        )

        let main = """
        fn main() {
            let mut integer = itoa::Buffer::new();
            let mut float = ryu::Buffer::new();
            println!("{} {}", integer.format(42), float.format_finite(3.14159));
        }
        """
        try main.write(
            to: sourceDirectory.appendingPathComponent("main.rs"),
            atomically: true,
            encoding: .utf8
        )

        let dockerfile = #"""
        # syntax=docker/dockerfile:1.7
        FROM rust:1-alpine
        WORKDIR /app
        COPY Cargo.toml ./
        COPY src ./src
        ARG CONJET_BENCH_ITERATION=0
        RUN --mount=type=cache,target=/usr/local/cargo/registry \
            echo "$CONJET_BENCH_ITERATION" >/tmp/conjet-bench-iteration \
            && cargo build --release
        """#
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

    private func warmupImages(for workloads: Set<String>) -> [String] {
        var images: [String] = []
        if !workloads.isDisjoint(with: ["container-start", "image-build", "copy-node-modules"]) {
            images.append("alpine:3.20")
        }
        if !workloads.isDisjoint(with: ["compose-up", "named-volume-io", "tmpfs-volume-io"]) {
            images.append("busybox:1.36")
        }
        if workloads.contains("npm-install") {
            images.append("node:22-alpine")
        }
        if workloads.contains("cargo-build") {
            images.append("rust:1-alpine")
        }
        return Array(Set(images)).sorted()
    }

    private func volumeWriteScript(directory: String) -> String {
        """
        i=0; while [ "$i" -lt 300 ]; do printf '%s\\n' "$i" > \(directory)/file-$i.txt; i=$((i + 1)); done; find \(directory) -type f -name 'file-*' | wc -l
        """
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

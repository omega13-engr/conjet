import ConjetCore
import Dispatch
import Foundation

private final class BenchmarkAsyncResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value?

    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func complete(_ value: Value) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard storedValue == nil else {
            return false
        }
        storedValue = value
        return true
    }
}

private final class BenchmarkStopwatchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var startDate: Date?

    func start() {
        lock.lock()
        startDate = Date()
        lock.unlock()
    }

    func elapsedSeconds() -> Double {
        lock.lock()
        let startedAt = startDate
        lock.unlock()
        guard let startedAt else {
            return 0
        }
        return Date().timeIntervalSince(startedAt)
    }
}

public struct DockerBenchmarkSuite {
    private static let hotReloadWaitSubscribeDelaySeconds: TimeInterval = 0.02
    private static let pnpmBenchmarkImage = "conjet-bench-node-pnpm:9.15.9"

    public static let defaultWorkloads = [
        "docker-version",
        "container-start",
        "image-build",
        "copy-node-modules",
        "npm-install",
        "pnpm-install",
        "cargo-build",
        "bind-npm-install",
        "bind-pnpm-install",
        "volume-npm-install",
        "volume-pnpm-install",
        "bind-cargo-build",
        "volume-cargo-build",
        "conjetfs-npm-install",
        "conjetfs-pnpm-install",
        "conjetfs-cargo-build",
        "bind-hot-reload",
        "conjetfs-hot-reload",
        "named-volume-io",
        "tmpfs-volume-io",
        "compose-up"
    ]

    public var contexts: [String]
    public var iterations: Int
    public var warmup: Bool
    public var dockerExecutable: String
    public var workloads: [String]
    public var commandTimeoutSeconds: Double

    private let runner: @Sendable (String, [String]) throws -> ProcessResult
    private let inputRunner: @Sendable (String, [String], Data?) throws -> ProcessResult

    public init(
        contexts: [String],
        iterations: Int = 1,
        warmup: Bool = false,
        workloads: [String] = DockerBenchmarkSuite.defaultWorkloads,
        dockerExecutable: String = "/usr/bin/env",
        commandTimeoutSeconds: Double = 180,
        runner: (@Sendable (String, [String]) throws -> ProcessResult)? = nil,
        inputRunner: (@Sendable (String, [String], Data?) throws -> ProcessResult)? = nil
    ) {
        self.contexts = contexts
        self.iterations = max(1, iterations)
        self.warmup = warmup
        self.workloads = workloads.isEmpty ? DockerBenchmarkSuite.defaultWorkloads : workloads
        self.dockerExecutable = dockerExecutable
        let timeout = max(1, commandTimeoutSeconds)
        self.commandTimeoutSeconds = timeout
        self.runner = runner ?? { executable, arguments in
            try ProcessRunner.run(executable, arguments, timeoutSeconds: timeout)
        }
        self.inputRunner = inputRunner ?? { executable, arguments, input in
            try ProcessRunner.runWithInput(
                executable,
                arguments,
                standardInput: input,
                timeoutSeconds: timeout
            )
        }
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
        let pnpmInstallDirectory = workDirectory.appendingPathComponent("pnpm-install", isDirectory: true)
        let cargoBuildDirectory = workDirectory.appendingPathComponent("cargo-build", isDirectory: true)
        let bindNPMDirectory = workDirectory.appendingPathComponent("bind-npm-install", isDirectory: true)
        let bindPNPMDirectory = workDirectory.appendingPathComponent("bind-pnpm-install", isDirectory: true)
        let bindCargoDirectory = workDirectory.appendingPathComponent("bind-cargo-build", isDirectory: true)
        let conjetFSNPMDirectory = workDirectory.appendingPathComponent("conjetfs-npm-install", isDirectory: true)
        let conjetFSPNPMDirectory = workDirectory.appendingPathComponent("conjetfs-pnpm-install", isDirectory: true)
        let conjetFSCargoDirectory = workDirectory.appendingPathComponent("conjetfs-cargo-build", isDirectory: true)
        let bindHotReloadDirectory = workDirectory.appendingPathComponent("bind-hot-reload", isDirectory: true)
        let conjetFSHotReloadDirectory = workDirectory.appendingPathComponent("conjetfs-hot-reload", isDirectory: true)
        let composeDirectory = workDirectory.appendingPathComponent("compose", isDirectory: true)
        try prepareBuildContext(at: buildDirectory)
        let nodeModulesFileCount = try prepareNodeModulesCopyContext(at: nodeModulesCopyDirectory)
        try prepareNPMInstallContext(at: npmInstallDirectory)
        try preparePNPMInstallContext(at: pnpmInstallDirectory)
        try prepareCargoBuildContext(at: cargoBuildDirectory)
        try prepareNPMProject(at: bindNPMDirectory)
        try preparePNPMProject(at: bindPNPMDirectory)
        try prepareCargoProject(at: bindCargoDirectory)
        try prepareConjetFSNodeProject(at: conjetFSNPMDirectory, packageManager: .npm)
        try prepareConjetFSNodeProject(at: conjetFSPNPMDirectory, packageManager: .pnpm)
        try prepareConjetFSCargoProject(at: conjetFSCargoDirectory)
        try prepareHotReloadProject(at: bindHotReloadDirectory, token: "initial")
        try prepareHotReloadProject(at: conjetFSHotReloadDirectory, token: "initial")
        let composeFile = try prepareComposeProject(at: composeDirectory)
        let conjetFSHome = workDirectory.appendingPathComponent(".conjetfs-home", isDirectory: true)

        var results: [BenchmarkResult] = []
        for context in contexts {
            for image in warmupImages(for: enabledWorkloads) {
                _ = try? runDocker(context: context, arguments: ["pull", image])
            }
            if requiresPNPMBenchmarkImage(enabledWorkloads) {
                try ensurePNPMBenchmarkImage(context: context, workDirectory: workDirectory)
            }
            if warmup {
                try warmupConjetPackageCaches(
                    context: context,
                    enabledWorkloads: enabledWorkloads,
                    bindNPMDirectory: bindNPMDirectory,
                    bindPNPMDirectory: bindPNPMDirectory,
                    conjetFSNPMDirectory: conjetFSNPMDirectory,
                    conjetFSPNPMDirectory: conjetFSPNPMDirectory,
                    homeDirectory: conjetFSHome
                )
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
                        arguments: buildArguments(["build", "-t", imageTag, buildDirectory.path])
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
                        arguments: buildArguments(["build", "-t", imageTag, nodeModulesCopyDirectory.path]),
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
                        arguments: buildArguments([
                            "build",
                            "--build-arg",
                            "CONJET_BENCH_ITERATION=\(iteration)",
                            "-t",
                            imageTag,
                            npmInstallDirectory.path
                        ]),
                        metrics: ["dependency_count": 3]
                    ))
                    _ = try? runDocker(context: context, arguments: ["rmi", "-f", imageTag])
                }

                if enabledWorkloads.contains("pnpm-install") {
                    let imageTag = "conjet-bench-\(context.sanitizedDockerTag)-pnpm-\(iteration)"
                    results.append(try benchmark(
                        workload: "pnpm-install",
                        context: context,
                        iteration: iteration,
                        arguments: buildArguments([
                            "build",
                            "--build-arg",
                            "CONJET_BENCH_ITERATION=\(iteration)",
                            "-t",
                            imageTag,
                            pnpmInstallDirectory.path
                        ]),
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
                        arguments: buildArguments([
                            "build",
                            "--build-arg",
                            "CONJET_BENCH_ITERATION=\(iteration)",
                            "-t",
                            imageTag,
                            cargoBuildDirectory.path
                        ]),
                        metrics: ["dependency_count": 2]
                    ))
                    _ = try? runDocker(context: context, arguments: ["rmi", "-f", imageTag])
                }

                if enabledWorkloads.contains("bind-npm-install") {
                    try resetNPMInstallArtifacts(at: bindNPMDirectory, preserveCaches: warmup)
                    results.append(try benchmark(
                        workload: "bind-npm-install",
                        context: context,
                        iteration: iteration,
                        arguments: [
                            "run",
                            "--rm",
                            "--mount",
                            "type=bind,source=\(bindNPMDirectory.path),target=/app",
                            "-w",
                            "/app",
                            "node:22-alpine",
                            "sh",
                            "-c",
                            npmInstallCommand() + " && test -d node_modules/lodash"
                        ],
                        metrics: ["dependency_count": 3]
                    ))
                }

                if enabledWorkloads.contains("bind-pnpm-install") {
                    try resetPNPMInstallArtifacts(at: bindPNPMDirectory, preserveCaches: warmup)
                    results.append(try benchmark(
                        workload: "bind-pnpm-install",
                        context: context,
                        iteration: iteration,
                        arguments: [
                            "run",
                            "--rm",
                            "--mount",
                            "type=bind,source=\(bindPNPMDirectory.path),target=/app",
                            "-w",
                            "/app",
                            Self.pnpmBenchmarkImage,
                            "sh",
                            "-c",
                            pnpmInstallCommand() + " && test -d node_modules/lodash"
                        ],
                        metrics: ["dependency_count": 3]
                    ))
                }

                if enabledWorkloads.contains("volume-npm-install") {
                    let volumeName = "conjet-bench-\(context.sanitizedDockerTag)-npm-volume-\(iteration)"
                    _ = try? runDocker(context: context, arguments: ["volume", "rm", "-f", volumeName])
                    results.append(try benchmark(
                        workload: "volume-npm-install",
                        context: context,
                        iteration: iteration,
                        arguments: [
                            "run",
                            "--rm",
                            "--mount",
                            "type=volume,source=\(volumeName),target=/app",
                            "-w",
                            "/app",
                            "node:22-alpine",
                            "sh",
                            "-c",
                            npmVolumeInstallScript()
                        ],
                        metrics: ["dependency_count": 3]
                    ))
                    _ = try? runDocker(context: context, arguments: ["volume", "rm", "-f", volumeName])
                }

                if enabledWorkloads.contains("volume-pnpm-install") {
                    let volumeName = "conjet-bench-\(context.sanitizedDockerTag)-pnpm-volume-\(iteration)"
                    _ = try? runDocker(context: context, arguments: ["volume", "rm", "-f", volumeName])
                    results.append(try benchmark(
                        workload: "volume-pnpm-install",
                        context: context,
                        iteration: iteration,
                        arguments: [
                            "run",
                            "--rm",
                            "--mount",
                            "type=volume,source=\(volumeName),target=/app",
                            "-w",
                            "/app",
                            Self.pnpmBenchmarkImage,
                            "sh",
                            "-c",
                            pnpmVolumeInstallScript()
                        ],
                        metrics: ["dependency_count": 3]
                    ))
                    _ = try? runDocker(context: context, arguments: ["volume", "rm", "-f", volumeName])
                }

                if enabledWorkloads.contains("bind-cargo-build") {
                    try resetCargoBuildArtifacts(at: bindCargoDirectory)
                    results.append(try benchmark(
                        workload: "bind-cargo-build",
                        context: context,
                        iteration: iteration,
                        arguments: [
                            "run",
                            "--rm",
                            "--mount",
                            "type=bind,source=\(bindCargoDirectory.path),target=/app",
                            "-w",
                            "/app",
                            "rust:1-alpine",
                            "sh",
                            "-c",
                            "cargo build --release && test -x target/release/conjet-cargo-build-benchmark"
                        ],
                        metrics: ["dependency_count": 2]
                    ))
                }

                if enabledWorkloads.contains("volume-cargo-build") {
                    let volumeName = "conjet-bench-\(context.sanitizedDockerTag)-cargo-volume-\(iteration)"
                    _ = try? runDocker(context: context, arguments: ["volume", "rm", "-f", volumeName])
                    results.append(try benchmark(
                        workload: "volume-cargo-build",
                        context: context,
                        iteration: iteration,
                        arguments: [
                            "run",
                            "--rm",
                            "--mount",
                            "type=volume,source=\(volumeName),target=/app",
                            "-w",
                            "/app",
                            "rust:1-alpine",
                            "sh",
                            "-c",
                            cargoVolumeBuildScript()
                        ],
                        metrics: ["dependency_count": 2]
                    ))
                    _ = try? runDocker(context: context, arguments: ["volume", "rm", "-f", volumeName])
                }

                if enabledWorkloads.contains("conjetfs-npm-install") {
                    try resetConjetFSProject(at: conjetFSNPMDirectory)
                    try prepareConjetFSNodeProject(at: conjetFSNPMDirectory, packageManager: .npm)
                    results.append(benchmarkConjetFSProject(
                        workload: "conjetfs-npm-install",
                        context: context,
                        iteration: iteration,
                        projectDirectory: conjetFSNPMDirectory,
                        homeDirectory: conjetFSHome,
                        image: "node:22-alpine",
                        shellCommand: npmInstallCommand(guestPath: "/workspace") + " && test -d node_modules/lodash",
                        usePackageCaches: warmup,
                        resetProjectVolume: !warmup,
                        metrics: ["dependency_count": 3]
                    ))
                }

                if enabledWorkloads.contains("conjetfs-pnpm-install") {
                    try resetConjetFSProject(at: conjetFSPNPMDirectory)
                    try prepareConjetFSNodeProject(at: conjetFSPNPMDirectory, packageManager: .pnpm)
                    results.append(benchmarkConjetFSProject(
                        workload: "conjetfs-pnpm-install",
                        context: context,
                        iteration: iteration,
                        projectDirectory: conjetFSPNPMDirectory,
                        homeDirectory: conjetFSHome,
                        image: Self.pnpmBenchmarkImage,
                        shellCommand: pnpmInstallCommand(guestPath: "/workspace") + " && test -d node_modules/lodash",
                        usePackageCaches: warmup,
                        resetProjectVolume: !warmup,
                        metrics: ["dependency_count": 3]
                    ))
                }

                if enabledWorkloads.contains("conjetfs-cargo-build") {
                    try resetConjetFSProject(at: conjetFSCargoDirectory)
                    try prepareConjetFSCargoProject(at: conjetFSCargoDirectory)
                    results.append(benchmarkConjetFSProject(
                        workload: "conjetfs-cargo-build",
                        context: context,
                        iteration: iteration,
                        projectDirectory: conjetFSCargoDirectory,
                        homeDirectory: conjetFSHome,
                        image: "rust:1-alpine",
                        shellCommand: "cargo build --release && test -x target/release/conjet-cargo-build-benchmark",
                        usePackageCaches: false,
                        resetProjectVolume: true,
                        metrics: ["dependency_count": 2]
                    ))
                }

                if enabledWorkloads.contains("bind-hot-reload") {
                    try resetHotReloadProject(at: bindHotReloadDirectory)
                    try prepareHotReloadProject(at: bindHotReloadDirectory, token: "initial-\(iteration)")
                    results.append(benchmarkBindHotReload(
                        context: context,
                        iteration: iteration,
                        projectDirectory: bindHotReloadDirectory
                    ))
                }

                if enabledWorkloads.contains("conjetfs-hot-reload") {
                    try resetConjetFSProject(at: conjetFSHotReloadDirectory)
                    try prepareHotReloadProject(at: conjetFSHotReloadDirectory, token: "initial-\(iteration)")
                    results.append(benchmarkConjetFSHotReload(
                        context: context,
                        iteration: iteration,
                        projectDirectory: conjetFSHotReloadDirectory,
                        homeDirectory: conjetFSHome
                    ))
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

    private var samplePhase: BenchmarkSamplePhase {
        warmup ? .warm : .cold
    }

    private func buildArguments(_ arguments: [String]) -> [String] {
        guard !warmup, arguments.first == "build" else {
            return arguments
        }
        return ["build", "--no-cache"] + arguments.dropFirst()
    }

    private func requiresPNPMBenchmarkImage(_ workloads: Set<String>) -> Bool {
        !workloads.isDisjoint(with: [
            "pnpm-install",
            "bind-pnpm-install",
            "volume-pnpm-install",
            "conjetfs-pnpm-install"
        ])
    }

    private func ensurePNPMBenchmarkImage(context: String, workDirectory: URL) throws {
        let imageDirectory = workDirectory
            .appendingPathComponent("pnpm-benchmark-image", isDirectory: true)
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        let dockerfile = #"""
        FROM node:22-alpine
        ENV COREPACK_ENABLE_PROJECT_SPEC=0
        RUN corepack disable >/dev/null 2>&1 || true \
            && npm install -g pnpm@9.15.9 >/dev/null \
            && pnpm --version >/dev/null
        """#
        try dockerfile.write(
            to: imageDirectory.appendingPathComponent("Dockerfile"),
            atomically: true,
            encoding: .utf8
        )
        let result = try runDocker(context: context, arguments: [
            "build",
            "-t",
            Self.pnpmBenchmarkImage,
            imageDirectory.path
        ])
        if !result.succeeded {
            throw ConjetError.processFailed(
                executable: dockerExecutable,
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
    }

    private func commonMetrics(_ metrics: [String: Double], iteration: Int) -> [String: Double] {
        var result = metrics
        result["iteration"] = Double(iteration)
        result[BenchmarkSamplePhase.metricKey] = samplePhase.metricValue ?? -1
        result["benchmark_warmup"] = warmup ? 1 : 0
        return result
    }

    private func warmupConjetPackageCaches(
        context: String,
        enabledWorkloads: Set<String>,
        bindNPMDirectory: URL,
        bindPNPMDirectory: URL,
        conjetFSNPMDirectory: URL,
        conjetFSPNPMDirectory: URL,
        homeDirectory: URL
    ) throws {
        if enabledWorkloads.contains("bind-npm-install") {
            try resetNPMInstallArtifacts(at: bindNPMDirectory, preserveCaches: false)
            try prepareNPMProject(at: bindNPMDirectory)
            _ = try? benchmark(
                workload: "bind-npm-install",
                context: context,
                iteration: 0,
                arguments: [
                    "run",
                    "--rm",
                    "--mount",
                    "type=bind,source=\(bindNPMDirectory.path),target=/app",
                    "-w",
                    "/app",
                    "node:22-alpine",
                    "sh",
                    "-c",
                    npmInstallCommand() + " && test -d node_modules/lodash"
                ],
                metrics: ["dependency_count": 3, "benchmark_warmup_sample": 1]
            )
            try resetNPMInstallArtifacts(at: bindNPMDirectory, preserveCaches: true)
        }

        if enabledWorkloads.contains("bind-pnpm-install") {
            try resetPNPMInstallArtifacts(at: bindPNPMDirectory, preserveCaches: false)
            try preparePNPMProject(at: bindPNPMDirectory)
            _ = try? benchmark(
                workload: "bind-pnpm-install",
                context: context,
                iteration: 0,
                arguments: [
                    "run",
                    "--rm",
                    "--mount",
                    "type=bind,source=\(bindPNPMDirectory.path),target=/app",
                    "-w",
                    "/app",
                    Self.pnpmBenchmarkImage,
                    "sh",
                    "-c",
                    pnpmInstallCommand() + " && test -d node_modules/lodash"
                ],
                metrics: ["dependency_count": 3, "benchmark_warmup_sample": 1]
            )
            try resetPNPMInstallArtifacts(at: bindPNPMDirectory, preserveCaches: true)
        }

        if enabledWorkloads.contains("conjetfs-npm-install") {
            try resetConjetFSProject(at: conjetFSNPMDirectory)
            try prepareConjetFSNodeProject(at: conjetFSNPMDirectory, packageManager: .npm)
            _ = benchmarkConjetFSProject(
                workload: "conjetfs-npm-install",
                context: context,
                iteration: 0,
                projectDirectory: conjetFSNPMDirectory,
                homeDirectory: homeDirectory,
                image: "node:22-alpine",
                shellCommand: npmInstallCommand(guestPath: "/workspace") + " && test -d node_modules/lodash",
                usePackageCaches: true,
                resetProjectVolume: true,
                metrics: ["dependency_count": 3, "benchmark_warmup_sample": 1]
            )
        }

        if enabledWorkloads.contains("conjetfs-pnpm-install") {
            try resetConjetFSProject(at: conjetFSPNPMDirectory)
            try prepareConjetFSNodeProject(at: conjetFSPNPMDirectory, packageManager: .pnpm)
            _ = benchmarkConjetFSProject(
                workload: "conjetfs-pnpm-install",
                context: context,
                iteration: 0,
                projectDirectory: conjetFSPNPMDirectory,
                homeDirectory: homeDirectory,
                image: Self.pnpmBenchmarkImage,
                shellCommand: pnpmInstallCommand(guestPath: "/workspace") + " && test -d node_modules/lodash",
                usePackageCaches: true,
                resetProjectVolume: true,
                metrics: ["dependency_count": 3, "benchmark_warmup_sample": 1]
            )
        }
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
        let resultMetrics = commonMetrics(metrics, iteration: iteration)
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

    private func benchmarkConjetFSProject(
        workload: String,
        context: String,
        iteration: Int,
        projectDirectory: URL,
        homeDirectory: URL,
        image: String,
        shellCommand: String,
        usePackageCaches: Bool,
        resetProjectVolume: Bool,
        metrics: [String: Double]
    ) -> BenchmarkResult {
        var command = dockerArguments(context: context, arguments: [
            "run",
            "--rm",
            "--mount",
            "type=volume,source=conjetfs,target=/workspace",
            "-w",
            "/workspace",
            image,
            "sh",
            "-c",
            shellCommand
        ])
        let machine = MachineProfiler.capture()
        var startedAt = Date()
        var resultMetrics = commonMetrics(metrics, iteration: iteration)
        var stdout = ""
        var stderr = ""
        var exitCode: Int32 = 0

        do {
            let paths = ConjetPaths(home: homeDirectory, profileName: context.sanitizedDockerTag)
            let fs = ConjetFS(
                projectRoot: projectDirectory,
                paths: paths,
                dockerContext: context,
                runner: runner,
                inputRunner: inputRunner,
                streamingHelperFastPath: true
            )
            let project = try fs.loadOrInitializeProject()
            if resetProjectVolume {
                _ = try? runDocker(context: context, arguments: ["volume", "rm", "-f", project.dockerVolume])
                let createVolume = try runDocker(context: context, arguments: ["volume", "create", project.dockerVolume])
                if !createVolume.succeeded {
                    throw ConjetError.processFailed(
                        executable: dockerExecutable,
                        exitCode: createVolume.exitCode,
                        stderr: createVolume.stderr
                    )
                }
            }
            startedAt = Date()
            let syncPrepareStartedAt = Date()
            var syncPrepareEndedAt = syncPrepareStartedAt
            let measuredShellCommand = usePackageCaches
                ? "rm -rf node_modules && \(shellCommand)"
                : shellCommand
            let fused = try fs.withSyncMountedRun(project: project) { preparation in
                syncPrepareEndedAt = Date()
                let runArguments = dockerArguments(
                    context: context,
                    arguments: [
                        "run",
                        "--rm"
                    ] + preparation.dockerMountArguments +
                        conjetPackageCacheMountArguments(
                            context: context,
                            guestPath: preparation.sync.guestPath,
                            shellCommand: shellCommand,
                            enabled: usePackageCaches
                        ) + [
                        "-w",
                        preparation.sync.guestPath,
                        image,
                        "sh",
                        "-c",
                        "\(preparation.shellPrelude) && \(measuredShellCommand)"
                    ]
                )
                command = runArguments
                return try runner(dockerExecutable, runArguments)
            }
            resultMetrics["sync_seconds"] = syncPrepareEndedAt.timeIntervalSince(syncPrepareStartedAt)
            resultMetrics["sync_fused_run"] = 1
            resultMetrics["project_volume_reused"] = resetProjectVolume ? 0 : 1
            resultMetrics["package_cache_mounts"] = Double(
                conjetPackageCacheMountArguments(
                    context: context,
                    guestPath: fused.sync.guestPath,
                    shellCommand: shellCommand,
                    enabled: usePackageCaches
                ).count / 2
            )
            resultMetrics["synced_files"] = Double(fused.sync.includedFiles)
            resultMetrics["skipped_files"] = Double(fused.sync.skippedFiles)
            resultMetrics["synced_bytes"] = Double(fused.sync.includedBytes)
            stdout = "ConjetFS synced \(fused.sync.includedFiles) files, skipped \(fused.sync.skippedFiles) files\n" + fused.process.stdout
            stderr = fused.process.stderr
            exitCode = fused.process.exitCode
        } catch let ConjetError.processFailed(_, failedExitCode, failedStderr) {
            exitCode = failedExitCode
            stderr = failedStderr
        } catch {
            exitCode = 1
            stderr = String(describing: error)
        }

        return BenchmarkResult(
            workload: workload,
            runtime: context,
            command: [dockerExecutable] + command,
            startedAt: startedAt,
            durationSeconds: Date().timeIntervalSince(startedAt),
            exitCode: exitCode,
            metrics: resultMetrics,
            machine: machine,
            stdoutTail: tail(stdout),
            stderrTail: tail(stderr)
        )
    }

    private func benchmarkBindHotReload(
        context: String,
        iteration: Int,
        projectDirectory: URL
    ) -> BenchmarkResult {
        let containerName = "conjet-bench-\(context.sanitizedDockerTag)-bind-hot-\(iteration)"
        let token = "hot-\(context.sanitizedDockerTag)-\(iteration)-\(UUID().uuidString.prefix(8))"
        let runArguments = [
            "run",
            "-d",
            "--name",
            containerName,
            "--mount",
            "type=bind,source=\(projectDirectory.path),target=/app",
            "-w",
            "/app",
            "node:22-alpine",
            "node",
            "-e",
            hotReloadWatchScript(path: "/app/src/hot.txt", token: token)
        ]
        return benchmarkHotReload(
            workload: "bind-hot-reload",
            context: context,
            iteration: iteration,
            runArguments: runArguments,
            containerName: containerName,
            token: token,
            hotFile: projectDirectory.appendingPathComponent("src/hot.txt")
        )
    }

    private func benchmarkConjetFSHotReload(
        context: String,
        iteration: Int,
        projectDirectory: URL,
        homeDirectory: URL
    ) -> BenchmarkResult {
        let containerName = "conjet-bench-\(context.sanitizedDockerTag)-conjetfs-hot-\(iteration)"
        let token = "hot-\(context.sanitizedDockerTag)-\(iteration)-\(UUID().uuidString.prefix(8))"
        let machine = MachineProfiler.capture()
        let command = dockerArguments(context: context, arguments: [
            "run",
            "-d",
            "--name",
            containerName,
            "--mount",
            "type=volume,source=conjetfs,target=/workspace",
            "-w",
            "/workspace",
            "node:22-alpine",
            "node",
            "-e",
            hotReloadWatchScript(path: "/workspace/src/hot.txt", token: token)
        ])
        _ = try? runDocker(context: context, arguments: ["rm", "-f", containerName])
        var metrics = commonMetrics([:], iteration: iteration)
        var stdout = ""
        var stderr = ""
        var exitCode: Int32 = 0
        var startedAt = Date()

        do {
            let paths = ConjetPaths(home: homeDirectory, profileName: context.sanitizedDockerTag)
            let fs = ConjetFS(
                projectRoot: projectDirectory,
                paths: paths,
                dockerContext: context,
                runner: runner,
                inputRunner: inputRunner,
                streamingHelperFastPath: true
            )
            let project = try fs.loadOrInitializeProject()
            _ = try? runDocker(context: context, arguments: ["volume", "rm", "-f", project.dockerVolume])
            startedAt = Date()
            let initialSync = try fs.sync(project: project)
            metrics["initial_synced_files"] = Double(initialSync.includedFiles)
            metrics["initial_skipped_files"] = Double(initialSync.skippedFiles)
            let syncHelper = try fs.startSyncHelper(project: project)
            defer { fs.stopSyncHelper(syncHelper) }

            let concreteRunArguments = dockerArguments(context: context, arguments: [
                "run",
                "-d",
                "--name",
                containerName,
                "--mount",
                "type=volume,source=\(initialSync.dockerVolume),target=\(initialSync.guestPath)",
                "-w",
                initialSync.guestPath,
                "node:22-alpine",
                "node",
                "-e",
                hotReloadWatchScript(path: "\(initialSync.guestPath)/src/hot.txt", token: token)
            ])
            let runResult = try runner(dockerExecutable, concreteRunArguments)
            guard runResult.succeeded else {
                exitCode = runResult.exitCode
                stderr = runResult.stderr.isEmpty ? runResult.stdout : runResult.stderr
                return BenchmarkResult(
                    workload: "conjetfs-hot-reload",
                    runtime: context,
                    command: [dockerExecutable] + command,
                    startedAt: startedAt,
                    durationSeconds: Date().timeIntervalSince(startedAt),
                    exitCode: exitCode,
                    metrics: metrics,
                    machine: machine,
                    stdoutTail: tail(stdout),
                    stderrTail: tail(stderr)
                )
            }
            defer {
                _ = try? runDocker(context: context, arguments: ["rm", "-f", containerName])
            }

            let readyStartedAt = Date()
            try waitForHotReloadWatcherReady(context: context, containerName: containerName)
            metrics["watcher_ready_seconds"] = Date().timeIntervalSince(readyStartedAt)
            let syncSemaphore = DispatchSemaphore(value: 0)
            let syncLock = NSLock()
            var syncCompleted = false
            var syncResult: Result<(ConjetFSSyncResult, ConjetFSWatchEvent, Double), Error>?
            let watcher = ConjetFSHostEventStream(root: projectDirectory, debounceSeconds: 0.001)
            let waitSemaphore = DispatchSemaphore(value: 0)
            let waitResult = BenchmarkAsyncResultBox<Result<(ProcessResult, Double), Error>>()
            let detectionTimer = BenchmarkStopwatchBox()
            let waitArguments = dockerArguments(context: context, arguments: ["wait", containerName])
            let waitRunner = runner
            let waitExecutable = dockerExecutable
            metrics["docker_wait_subscribe_delay_seconds"] = Self.hotReloadWaitSubscribeDelaySeconds

            func completeSync(_ result: Result<(ConjetFSSyncResult, ConjetFSWatchEvent, Double), Error>) {
                syncLock.lock()
                defer { syncLock.unlock() }
                guard !syncCompleted else {
                    return
                }
                syncCompleted = true
                syncResult = result
                syncSemaphore.signal()
            }

            @Sendable func completeWait(_ result: Result<(ProcessResult, Double), Error>) {
                if waitResult.complete(result) {
                    waitSemaphore.signal()
                }
            }

            try watcher.start { event in
                do {
                    let syncStartedAt = Date()
                    let updateSync = try fs.sync(
                        project: project,
                        changedPaths: event.changedPaths,
                        helperContainer: syncHelper
                    )
                    guard updateSync.changedFiles > 0 || updateSync.removedFiles > 0 else {
                        return
                    }
                    completeSync(.success((updateSync, event, Date().timeIntervalSince(syncStartedAt))))
                } catch {
                    completeSync(.failure(error))
                }
            }
            defer { watcher.stop() }

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try waitRunner(waitExecutable, waitArguments)
                    completeWait(.success((result, detectionTimer.elapsedSeconds())))
                } catch {
                    completeWait(.failure(error))
                }
            }
            Thread.sleep(forTimeInterval: Self.hotReloadWaitSubscribeDelaySeconds)
            let watchSyncStartedAt = Date()
            detectionTimer.start()
            try token.write(to: projectDirectory.appendingPathComponent("src/hot.txt"), atomically: true, encoding: .utf8)

            let timeout = DispatchTime.now() + .seconds(5)
            guard syncSemaphore.wait(timeout: timeout) == .success else {
                exitCode = 124
                stderr = "ConjetFS FSEvents hot reload timed out before the changed file was synced"
                metrics["watch_timeout"] = 1
                metrics["watch_wait_seconds"] = Date().timeIntervalSince(watchSyncStartedAt)
                return BenchmarkResult(
                    workload: "conjetfs-hot-reload",
                    runtime: context,
                    command: [dockerExecutable] + command,
                    startedAt: startedAt,
                    durationSeconds: Date().timeIntervalSince(startedAt),
                    exitCode: exitCode,
                    metrics: metrics,
                    machine: machine,
                    stdoutTail: tail(stdout),
                    stderrTail: tail(stderr)
                )
            }

            guard waitSemaphore.wait(timeout: DispatchTime.now() + .seconds(6)) == .success else {
                exitCode = 124
                stderr = "ConjetFS hot reload timed out before the container observed the changed file"
                metrics["container_wait_timeout"] = 1
                metrics["watch_wait_seconds"] = Date().timeIntervalSince(watchSyncStartedAt)
                return BenchmarkResult(
                    workload: "conjetfs-hot-reload",
                    runtime: context,
                    command: [dockerExecutable] + command,
                    startedAt: startedAt,
                    durationSeconds: Date().timeIntervalSince(startedAt),
                    exitCode: exitCode,
                    metrics: metrics,
                    machine: machine,
                    stdoutTail: tail(stdout),
                    stderrTail: tail(stderr)
                )
            }

            syncLock.lock()
            let completedSyncResult = syncResult
            syncLock.unlock()
            let completedWaitResult = waitResult.value

            guard let syncResult = completedSyncResult else {
                exitCode = 1
                stderr = "ConjetFS FSEvents hot reload completed without sync result"
                return BenchmarkResult(
                    workload: "conjetfs-hot-reload",
                    runtime: context,
                    command: [dockerExecutable] + command,
                    startedAt: startedAt,
                    durationSeconds: Date().timeIntervalSince(startedAt),
                    exitCode: exitCode,
                    metrics: metrics,
                    machine: machine,
                    stdoutTail: tail(stdout),
                    stderrTail: tail(stderr)
                )
            }
            guard let waitResult = completedWaitResult else {
                exitCode = 1
                stderr = "ConjetFS hot reload completed without container wait result"
                return BenchmarkResult(
                    workload: "conjetfs-hot-reload",
                    runtime: context,
                    command: [dockerExecutable] + command,
                    startedAt: startedAt,
                    durationSeconds: Date().timeIntervalSince(startedAt),
                    exitCode: exitCode,
                    metrics: metrics,
                    machine: machine,
                    stdoutTail: tail(stdout),
                    stderrTail: tail(stderr)
                )
            }

            let updateSync: ConjetFSSyncResult
            let event: ConjetFSWatchEvent
            let syncSeconds: Double
            switch syncResult {
            case .success(let value):
                updateSync = value.0
                event = value.1
                syncSeconds = value.2
            case .failure(let error):
                exitCode = 1
                stderr = String(describing: error)
                return BenchmarkResult(
                    workload: "conjetfs-hot-reload",
                    runtime: context,
                    command: [dockerExecutable] + command,
                    startedAt: startedAt,
                    durationSeconds: Date().timeIntervalSince(startedAt),
                    exitCode: exitCode,
                    metrics: metrics,
                    machine: machine,
                    stdoutTail: tail(stdout),
                    stderrTail: tail(stderr)
                )
            }
            let containerWait: ProcessResult
            let detectionSeconds: Double
            switch waitResult {
            case .success(let value):
                containerWait = value.0
                detectionSeconds = value.1
            case .failure(let error):
                exitCode = 1
                stderr = String(describing: error)
                return BenchmarkResult(
                    workload: "conjetfs-hot-reload",
                    runtime: context,
                    command: [dockerExecutable] + command,
                    startedAt: startedAt,
                    durationSeconds: Date().timeIntervalSince(startedAt),
                    exitCode: exitCode,
                    metrics: metrics,
                    machine: machine,
                    stdoutTail: tail(stdout),
                    stderrTail: tail(stderr)
                )
            }

            metrics["update_synced_files"] = Double(updateSync.changedFiles)
            metrics["update_synced_bytes"] = Double(updateSync.changedBytes)
            metrics["watch_event_paths"] = Double(event.changedPaths.count)
            metrics["watch_sync_seconds"] = syncSeconds
            metrics["watch_wait_seconds"] = Date().timeIntervalSince(watchSyncStartedAt)
            metrics["hot_reload_seconds"] = detectionSeconds
            let logs = try? runDocker(context: context, arguments: ["logs", containerName])
            stdout = "ConjetFS hot reload synced \(updateSync.changedFiles) files\n" + (logs?.stdout ?? containerWait.stdout)
            stderr = containerWait.stderr + (logs?.stderr ?? "")
            exitCode = containerExitCode(from: containerWait)
        } catch let ConjetError.processFailed(_, failedExitCode, failedStderr) {
            exitCode = failedExitCode
            stderr = failedStderr
        } catch {
            exitCode = 1
            stderr = String(describing: error)
        }
        return BenchmarkResult(
            workload: "conjetfs-hot-reload",
            runtime: context,
            command: [dockerExecutable] + command,
            startedAt: startedAt,
            durationSeconds: Date().timeIntervalSince(startedAt),
            exitCode: exitCode,
            metrics: metrics,
            machine: machine,
            stdoutTail: tail(stdout),
            stderrTail: tail(stderr)
        )
    }

    private func benchmarkHotReload(
        workload: String,
        context: String,
        iteration: Int,
        runArguments: [String],
        containerName: String,
        token: String,
        hotFile: URL
    ) -> BenchmarkResult {
        let machine = MachineProfiler.capture()
        let command = dockerArguments(context: context, arguments: runArguments)
        _ = try? runDocker(context: context, arguments: ["rm", "-f", containerName])
        let startedAt = Date()
        var metrics = commonMetrics([:], iteration: iteration)
        var stdout = ""
        var stderr = ""
        var exitCode: Int32 = 0
        do {
            let runResult = try runner(dockerExecutable, command)
            guard runResult.succeeded else {
                exitCode = runResult.exitCode
                stderr = runResult.stderr.isEmpty ? runResult.stdout : runResult.stderr
                return BenchmarkResult(
                    workload: workload,
                    runtime: context,
                    command: [dockerExecutable] + command,
                    startedAt: startedAt,
                    durationSeconds: Date().timeIntervalSince(startedAt),
                    exitCode: exitCode,
                    metrics: metrics,
                    machine: machine,
                    stdoutTail: tail(stdout),
                    stderrTail: tail(stderr)
                )
            }

            let readyStartedAt = Date()
            try waitForHotReloadWatcherReady(context: context, containerName: containerName)
            metrics["watcher_ready_seconds"] = Date().timeIntervalSince(readyStartedAt)
            let waitSemaphore = DispatchSemaphore(value: 0)
            let waitResult = BenchmarkAsyncResultBox<Result<(ProcessResult, Double), Error>>()
            let detectionTimer = BenchmarkStopwatchBox()
            let waitArguments = dockerArguments(context: context, arguments: ["wait", containerName])
            let waitRunner = runner
            let waitExecutable = dockerExecutable
            metrics["docker_wait_subscribe_delay_seconds"] = Self.hotReloadWaitSubscribeDelaySeconds

            @Sendable func completeWait(_ result: Result<(ProcessResult, Double), Error>) {
                if waitResult.complete(result) {
                    waitSemaphore.signal()
                }
            }

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try waitRunner(waitExecutable, waitArguments)
                    completeWait(.success((result, detectionTimer.elapsedSeconds())))
                } catch {
                    completeWait(.failure(error))
                }
            }
            Thread.sleep(forTimeInterval: Self.hotReloadWaitSubscribeDelaySeconds)
            detectionTimer.start()
            try token.write(to: hotFile, atomically: false, encoding: .utf8)

            guard waitSemaphore.wait(timeout: DispatchTime.now() + .seconds(6)) == .success else {
                exitCode = 124
                stderr = "\(workload) timed out before the container observed the changed file"
                metrics["container_wait_timeout"] = 1
                return BenchmarkResult(
                    workload: workload,
                    runtime: context,
                    command: [dockerExecutable] + command,
                    startedAt: startedAt,
                    durationSeconds: Date().timeIntervalSince(startedAt),
                    exitCode: exitCode,
                    metrics: metrics,
                    machine: machine,
                    stdoutTail: tail(stdout),
                    stderrTail: tail(stderr)
                )
            }

            guard let completedWaitResult = waitResult.value else {
                exitCode = 1
                stderr = "\(workload) completed without container wait result"
                return BenchmarkResult(
                    workload: workload,
                    runtime: context,
                    command: [dockerExecutable] + command,
                    startedAt: startedAt,
                    durationSeconds: Date().timeIntervalSince(startedAt),
                    exitCode: exitCode,
                    metrics: metrics,
                    machine: machine,
                    stdoutTail: tail(stdout),
                    stderrTail: tail(stderr)
                )
            }

            let containerWait: ProcessResult
            let detectionSeconds: Double
            switch completedWaitResult {
            case .success(let value):
                containerWait = value.0
                detectionSeconds = value.1
            case .failure(let error):
                exitCode = 1
                stderr = String(describing: error)
                return BenchmarkResult(
                    workload: workload,
                    runtime: context,
                    command: [dockerExecutable] + command,
                    startedAt: startedAt,
                    durationSeconds: Date().timeIntervalSince(startedAt),
                    exitCode: exitCode,
                    metrics: metrics,
                    machine: machine,
                    stdoutTail: tail(stdout),
                    stderrTail: tail(stderr)
                )
            }

            metrics["hot_reload_seconds"] = detectionSeconds
            let logs = try? runDocker(context: context, arguments: ["logs", containerName])
            stdout = logs?.stdout ?? containerWait.stdout
            stderr = containerWait.stderr + (logs?.stderr ?? "")
            exitCode = containerExitCode(from: containerWait)
        } catch let ConjetError.processFailed(_, failedExitCode, failedStderr) {
            exitCode = failedExitCode
            stderr = failedStderr
        } catch {
            exitCode = 1
            stderr = String(describing: error)
        }
        _ = try? runDocker(context: context, arguments: ["rm", "-f", containerName])

        return BenchmarkResult(
            workload: workload,
            runtime: context,
            command: [dockerExecutable] + command,
            startedAt: startedAt,
            durationSeconds: Date().timeIntervalSince(startedAt),
            exitCode: exitCode,
            metrics: metrics,
            machine: machine,
            stdoutTail: tail(stdout),
            stderrTail: tail(stderr)
        )
    }

    private func runDocker(context: String, arguments: [String]) throws -> ProcessResult {
        try runner(dockerExecutable, dockerArguments(context: context, arguments: arguments))
    }

    private func dockerArguments(context: String, arguments: [String]) -> [String] {
        ["docker", "--context", context] + arguments
    }

    private func waitForHotReloadWatcherReady(context: String, containerName: String) throws {
        let deadline = Date().addingTimeInterval(5)
        var lastResult: ProcessResult?
        repeat {
            let result = try runDocker(
                context: context,
                arguments: ["exec", containerName, "test", "-f", "/tmp/conjet-hot-reload-ready"]
            )
            if result.succeeded {
                return
            }
            lastResult = result
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline

        let stderr = lastResult?.stderr.isEmpty == false ? lastResult?.stderr ?? "" : lastResult?.stdout ?? ""
        throw ConjetError.unavailable("hot reload watcher did not become ready in \(containerName): \(stderr)")
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
        try prepareNPMProject(at: directory)
        let dockerfile = #"""
        # syntax=docker/dockerfile:1.7
        FROM node:22-alpine
        WORKDIR /app
        COPY package.json package-lock.json ./
        ARG CONJET_BENCH_ITERATION=0
        RUN --mount=type=cache,target=/root/.npm \
            echo "$CONJET_BENCH_ITERATION" >/tmp/conjet-bench-iteration \
            && \#(npmInstallCommand()) \
            && node -e "const _ = require('lodash'); console.log(_.camelCase('conjet npm install benchmark'))"
        """#
        try dockerfile.write(
            to: directory.appendingPathComponent("Dockerfile"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func preparePNPMInstallContext(at directory: URL) throws {
        try preparePNPMProject(at: directory)
        let dockerfile = #"""
        # syntax=docker/dockerfile:1.7
        FROM \#(Self.pnpmBenchmarkImage)
        WORKDIR /app
        COPY package.json pnpm-lock.yaml ./
        ARG CONJET_BENCH_ITERATION=0
        RUN --mount=type=cache,target=/root/.npm \
            echo "$CONJET_BENCH_ITERATION" >/tmp/conjet-bench-iteration \
            && \#(pnpmInstallCommand()) \
            && node -e "const _ = require('lodash'); console.log(_.camelCase('conjet pnpm install benchmark'))"
        """#
        try dockerfile.write(
            to: directory.appendingPathComponent("Dockerfile"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func prepareNPMProject(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try nodeBenchmarkPackageJSON().write(
            to: directory.appendingPathComponent("package.json"),
            atomically: true,
            encoding: .utf8
        )
        try nodeBenchmarkPackageLock().write(
            to: directory.appendingPathComponent("package-lock.json"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func preparePNPMProject(at directory: URL) throws {
        try prepareNPMProject(at: directory)
        let packageLock = directory.appendingPathComponent("package-lock.json")
        if FileManager.default.fileExists(atPath: packageLock.path) {
            try FileManager.default.removeItem(at: packageLock)
        }
        try nodeBenchmarkPNPMLock().write(
            to: directory.appendingPathComponent("pnpm-lock.yaml"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func nodeBenchmarkPackageJSON() -> String {
        """
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
    }

    private func nodeBenchmarkPackageLock() -> String {
        #"""
        {
          "name": "conjet-npm-install-benchmark",
          "version": "1.0.0",
          "lockfileVersion": 3,
          "requires": true,
          "packages": {
            "": {
              "name": "conjet-npm-install-benchmark",
              "version": "1.0.0",
              "dependencies": {
                "is-number": "7.0.0",
                "lodash": "4.17.21",
                "nanoid": "5.0.7"
              }
            },
            "node_modules/is-number": {
              "version": "7.0.0",
              "resolved": "https://registry.npmjs.org/is-number/-/is-number-7.0.0.tgz",
              "integrity": "sha512-41Cifkg6e8TylSpdtTpeLVMqvSBEVzTttHvERD741+pnZ8ANv0004MRL43QKPDlK9cGvNp6NZWZUBlbGXYxxng==",
              "license": "MIT",
              "engines": {
                "node": ">=0.12.0"
              }
            },
            "node_modules/lodash": {
              "version": "4.17.21",
              "resolved": "https://registry.npmjs.org/lodash/-/lodash-4.17.21.tgz",
              "integrity": "sha512-v2kDEe57lecTulaDIuNTPy3Ry4gLGJ6Z1O3vE1krgXZNrsQ+LFTGHVxVjcXPs17LhbZVGedAJv8XZ1tvj5FvSg==",
              "license": "MIT"
            },
            "node_modules/nanoid": {
              "version": "5.0.7",
              "resolved": "https://registry.npmjs.org/nanoid/-/nanoid-5.0.7.tgz",
              "integrity": "sha512-oLxFY2gd2IqnjcYyOXD8XGCftpGtZP2AbHbOkthDkvRywH5ayNtPVy9YlOPcHckXzbLTCHpkb7FB+yuxKV13pQ==",
              "funding": [
                {
                  "type": "github",
                  "url": "https://github.com/sponsors/ai"
                }
              ],
              "license": "MIT",
              "bin": {
                "nanoid": "bin/nanoid.js"
              },
              "engines": {
                "node": "^18 || >=20"
              }
            }
          }
        }
        """#
    }

    private func nodeBenchmarkPNPMLock() -> String {
        #"""
        lockfileVersion: '9.0'

        settings:
          autoInstallPeers: true
          excludeLinksFromLockfile: false

        importers:

          .:
            dependencies:
              is-number:
                specifier: 7.0.0
                version: 7.0.0
              lodash:
                specifier: 4.17.21
                version: 4.17.21
              nanoid:
                specifier: 5.0.7
                version: 5.0.7

        packages:

          is-number@7.0.0:
            resolution: {integrity: sha512-41Cifkg6e8TylSpdtTpeLVMqvSBEVzTttHvERD741+pnZ8ANv0004MRL43QKPDlK9cGvNp6NZWZUBlbGXYxxng==}
            engines: {node: '>=0.12.0'}

          lodash@4.17.21:
            resolution: {integrity: sha512-v2kDEe57lecTulaDIuNTPy3Ry4gLGJ6Z1O3vE1krgXZNrsQ+LFTGHVxVjcXPs17LhbZVGedAJv8XZ1tvj5FvSg==}

          nanoid@5.0.7:
            resolution: {integrity: sha512-oLxFY2gd2IqnjcYyOXD8XGCftpGtZP2AbHbOkthDkvRywH5ayNtPVy9YlOPcHckXzbLTCHpkb7FB+yuxKV13pQ==}
            engines: {node: ^18 || >=20}
            hasBin: true

        snapshots:

          is-number@7.0.0: {}

          lodash@4.17.21: {}

          nanoid@5.0.7: {}
        """#
    }

    private enum NodePackageManager {
        case npm
        case pnpm
    }

    private func prepareConjetFSNodeProject(at directory: URL, packageManager: NodePackageManager) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("src", isDirectory: true),
            withIntermediateDirectories: true
        )
        switch packageManager {
        case .npm:
            try prepareNPMProject(at: directory)
        case .pnpm:
            try preparePNPMProject(at: directory)
        }
        try "console.log('conjetfs benchmark')\n".write(
            to: directory.appendingPathComponent("src/index.js"),
            atomically: true,
            encoding: .utf8
        )
        try prepareHostDependencyNoise(
            at: directory.appendingPathComponent("node_modules", isDirectory: true),
            packagePrefix: "conjetfs-host-node-module"
        )
    }

    private func prepareCargoBuildContext(at directory: URL) throws {
        try prepareCargoProject(at: directory)
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

    private func prepareConjetFSCargoProject(at directory: URL) throws {
        try prepareCargoProject(at: directory)
        try prepareHostDependencyNoise(
            at: directory.appendingPathComponent("target/debug/deps", isDirectory: true),
            packagePrefix: "conjetfs-host-cargo-artifact"
        )
    }

    private func prepareHotReloadProject(at directory: URL, token: String) throws {
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("src", isDirectory: true),
            withIntermediateDirectories: true
        )
        try token.write(
            to: directory.appendingPathComponent("src/hot.txt"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"name":"conjet-hot-reload-benchmark","private":true}"#.write(
            to: directory.appendingPathComponent("package.json"),
            atomically: true,
            encoding: .utf8
        )
        try prepareHostDependencyNoise(
            at: directory.appendingPathComponent("node_modules", isDirectory: true),
            packagePrefix: "conjetfs-hot-host-node-module"
        )
    }

    private func prepareHostDependencyNoise(at directory: URL, packagePrefix: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for packageIndex in 0..<4 {
            let package = directory.appendingPathComponent("\(packagePrefix)-\(packageIndex)", isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            for fileIndex in 0..<40 {
                try "host-only generated file \(packageIndex)-\(fileIndex)\n".write(
                    to: package.appendingPathComponent("file-\(fileIndex).txt"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }
    }

    private func prepareCargoProject(at directory: URL) throws {
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
        if !workloads.isDisjoint(with: ["container-start", "image-build", "copy-node-modules", "conjetfs-npm-install", "conjetfs-pnpm-install", "conjetfs-cargo-build"]) {
            images.append("alpine:3.20")
        }
        if !workloads.isDisjoint(with: ["compose-up", "named-volume-io", "tmpfs-volume-io"]) {
            images.append("busybox:1.36")
        }
        if !workloads.isDisjoint(with: ["npm-install", "pnpm-install", "bind-npm-install", "bind-pnpm-install", "volume-npm-install", "volume-pnpm-install", "conjetfs-npm-install", "conjetfs-pnpm-install", "bind-hot-reload", "conjetfs-hot-reload"]) {
            images.append("node:22-alpine")
        }
        if !workloads.isDisjoint(with: ["cargo-build", "bind-cargo-build", "volume-cargo-build", "conjetfs-cargo-build"]) {
            images.append("rust:1-alpine")
        }
        return Array(Set(images)).sorted()
    }

    private func resetNPMInstallArtifacts(at directory: URL, preserveCaches: Bool = false) throws {
        var names = ["node_modules"]
        if !preserveCaches {
            names.append(".npm-cache")
        }
        for name in names {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func resetPNPMInstallArtifacts(at directory: URL, preserveCaches: Bool = false) throws {
        var names = ["node_modules"]
        if !preserveCaches {
            names.append(contentsOf: [".corepack-cache", ".npm-cache", ".pnpm-store", ".pnpm-state"])
        }
        for name in names {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func resetCargoBuildArtifacts(at directory: URL) throws {
        for name in ["target", "Cargo.lock"] {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func resetConjetFSProject(at directory: URL) throws {
        for name in [".conjet", ".conjetignore", "node_modules", "package-lock.json", "pnpm-lock.yaml", "target", "Cargo.lock"] {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func resetHotReloadProject(at directory: URL) throws {
        for name in ["node_modules", "package-lock.json", "pnpm-lock.yaml"] {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func hotReloadWatchScript(path: String, token: String) -> String {
        let pathLiteral = Self.javascriptStringLiteral(path)
        let tokenLiteral = Self.javascriptStringLiteral(token)
        return """
        const fs = require('fs');
        const pathModule = require('path');
        const hotPath = \(pathLiteral);
        const token = \(tokenLiteral);
        const readyPath = '/tmp/conjet-hot-reload-ready';
        const basename = pathModule.basename(hotPath);
        let done = false;

        function check() {
          if (done) return;
          try {
            if (fs.readFileSync(hotPath, 'utf8').trim() === token) {
              done = true;
              console.log('hot-reload-detected');
              process.exit(0);
            }
          } catch (_) {}
        }

        function watch(target) {
          try {
            fs.watch(target, { persistent: true }, (_event, filename) => {
              if (!filename || filename.toString() === basename || target === hotPath) {
                check();
              }
            });
          } catch (_) {}
        }

        watch(pathModule.dirname(hotPath));
        watch(hotPath);
        fs.writeFileSync(readyPath, 'ready\\n');
        check();
        setInterval(check, 5);
        setTimeout(() => {
          if (!done) {
            console.error('hot-reload-timeout');
            process.exit(124);
          }
        }, 10000);
        """
    }

    private static func javascriptStringLiteral(_ value: String) -> String {
        var output = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\":
                output += "\\\\"
            case "\"":
                output += "\\\""
            case "\n":
                output += "\\n"
            case "\r":
                output += "\\r"
            case "\t":
                output += "\\t"
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
        return output
    }

    private func containerExitCode(from waitResult: ProcessResult) -> Int32 {
        guard waitResult.succeeded else { return waitResult.exitCode }
        let trimmed = waitResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let code = Int32(trimmed) else { return 0 }
        return code
    }

    private func pnpmInstallCommand(guestPath: String = "/app") -> String {
        "\(packageTopologyShellPrefix(manager: .pnpm, guestPath: guestPath)) && \(pnpmBootstrapCommand()) && pnpm install --frozen-lockfile --prefer-offline --ignore-scripts"
    }

    private func npmInstallCommand(guestPath: String = "/app") -> String {
        "\(packageTopologyShellPrefix(manager: .npm, guestPath: guestPath)) && npm install --prefer-offline --no-audit --no-fund --progress=false --ignore-scripts"
    }

    private func pnpmBootstrapCommand() -> String {
        "(command -v pnpm >/dev/null 2>&1 || (corepack enable >/dev/null 2>&1 && corepack prepare pnpm@9.15.9 --activate >/dev/null 2>&1 || npm install -g pnpm@9.15.9 >/dev/null))"
    }

    private func packageTopologyShellPrefix(manager: ConjetPackageManager, guestPath: String) -> String {
        let plan = ConjetPackageTopologyOptimizer.plan(manager: manager, guestPath: guestPath)
        guard !plan.environment.isEmpty else {
            return "true"
        }
        let exports = plan.environment
            .sorted { $0.key < $1.key }
            .map { "export \($0.key)=\(shellQuote($0.value))" }
        let directories = Array(Set(plan.environment.values.filter { $0.hasPrefix("/") }))
            .sorted()
            .map { "mkdir -p \(shellQuote($0))" }
        return (exports + directories).joined(separator: " && ")
    }

    private func conjetPackageCacheMountArguments(
        context: String,
        guestPath: String,
        shellCommand: String,
        enabled: Bool
    ) -> [String] {
        guard enabled && context == "conjet" else {
            return []
        }

        var mounts: [String] = []
        if shellCommand.contains("COREPACK_HOME=") {
            mounts += [
                "--mount",
                "type=volume,source=conjet-package-corepack-cache,target=\(guestPath)/.corepack-cache"
            ]
        }
        if shellCommand.contains("NPM_CONFIG_CACHE=") {
            mounts += [
                "--mount",
                "type=volume,source=conjet-package-npm-cache,target=\(guestPath)/.npm-cache"
            ]
        }
        return mounts
    }

    private func npmVolumeInstallScript() -> String {
        """
        \(writeShellFile(path: "package.json", delimiter: "JSON", content: nodeBenchmarkPackageJSON()))
        \(writeShellFile(path: "package-lock.json", delimiter: "LOCKJSON", content: nodeBenchmarkPackageLock()))
        \(npmInstallCommand()) && test -d node_modules/lodash
        """
    }

    private func pnpmVolumeInstallScript() -> String {
        """
        \(writeShellFile(path: "package.json", delimiter: "JSON", content: nodeBenchmarkPackageJSON()))
        \(writeShellFile(path: "pnpm-lock.yaml", delimiter: "PNPMLOCK", content: nodeBenchmarkPNPMLock()))
        \(pnpmInstallCommand()) && test -d node_modules/lodash
        """
    }

    private func writeShellFile(path: String, delimiter: String, content: String) -> String {
        let normalizedContent = content.trimmingCharacters(in: .newlines)
        return "cat > \(path) <<'\(delimiter)'\n\(normalizedContent)\n\(delimiter)"
    }

    private func cargoVolumeBuildScript() -> String {
        """
        mkdir -p src
        cat > Cargo.toml <<'TOML'
        [package]
        name = "conjet-cargo-build-benchmark"
        version = "0.1.0"
        edition = "2021"

        [dependencies]
        itoa = "1.0.11"
        ryu = "1.0.18"
        TOML
        cat > src/main.rs <<'RS'
        fn main() {
            let mut integer = itoa::Buffer::new();
            let mut float = ryu::Buffer::new();
            println!("{} {}", integer.format(42), float.format_finite(3.14159));
        }
        RS
        cargo build --release && test -x target/release/conjet-cargo-build-benchmark
        """
    }

    private func volumeWriteScript(directory: String) -> String {
        """
        i=0; while [ "$i" -lt 300 ]; do printf '%s\\n' "$i" > \(directory)/file-$i.txt; i=$((i + 1)); done; find \(directory) -type f -name 'file-*' | wc -l
        """
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
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

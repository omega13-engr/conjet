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

private struct BindNativeOverlayPlan {
    var mountArguments: [String]
    var volumeNames: [String]
    var writePaths: [String]

    static let empty = BindNativeOverlayPlan(mountArguments: [], volumeNames: [], writePaths: [])
}

public struct DockerBenchmarkSuite {
    private static let hotReloadWaitSubscribeDelaySeconds: TimeInterval = 0.02
    private static let pnpmBenchmarkImage = "conjet-bench-node-pnpm:9.15.9"
    private static let pnpmBenchmarkImageLock = NSLock()

    public static let defaultWorkloads = [
        "docker-version",
        "container-start",
        "image-build",
        "copy-node-modules",
        "npm-install",
        "pnpm-install",
        "cargo-build",
        "strict-bind-npm-install",
        "strict-bind-pnpm-install",
        "strict-bind-cargo-build",
        "smart-bind-npm-install",
        "smart-bind-pnpm-install",
        "smart-bind-cargo-build",
        "volume-npm-install",
        "volume-pnpm-install",
        "volume-cargo-build",
        "conjetfs-npm-install",
        "conjetfs-pnpm-install",
        "conjetfs-cargo-build",
        "strict-bind-hot-reload",
        "smart-bind-hot-reload",
        "conjetfs-hot-reload",
        "named-volume-io",
        "tmpfs-volume-io",
        "compose-up"
    ]

    public static let deprecatedWorkloadAliases: [String: String] = [
        "bind-npm-install": "smart-bind-npm-install",
        "bind-pnpm-install": "smart-bind-pnpm-install",
        "bind-cargo-build": "smart-bind-cargo-build",
        "bind-hot-reload": "smart-bind-hot-reload"
    ]

    public static let coldWorkloads = [
        "container-start-cold",
        "image-build-no-cache",
        "copy-node-modules-no-cache",
        "npm-install-no-cache",
        "pnpm-install-no-cache",
        "cargo-build-no-cache",
        "strict-bind-npm-install-cold",
        "smart-bind-npm-install-cold",
        "strict-bind-pnpm-install-cold",
        "smart-bind-pnpm-install-cold",
        "strict-bind-cargo-build-cold",
        "smart-bind-cargo-build-cold",
        "volume-npm-install-cold",
        "volume-pnpm-install-cold",
        "volume-cargo-build-cold",
        "conjetfs-npm-install-cold",
        "conjetfs-pnpm-install-cold",
        "conjetfs-cargo-build-cold",
        "compose-up-cold"
    ]

    public static var supportedWorkloads: [String] {
        defaultWorkloads + Array(deprecatedWorkloadAliases.keys).sorted() + coldWorkloads
    }

    public static func canonicalWorkloadName(_ workload: String) -> String {
        if let mapped = deprecatedWorkloadAliases[workload] {
            return mapped
        }
        switch workload {
        case "container-start-cold":
            return "container-start"
        case "image-build-no-cache":
            return "image-build"
        case "copy-node-modules-no-cache":
            return "copy-node-modules"
        case "npm-install-no-cache":
            return "npm-install"
        case "pnpm-install-no-cache":
            return "pnpm-install"
        case "cargo-build-no-cache":
            return "cargo-build"
        case "strict-bind-npm-install-cold":
            return "strict-bind-npm-install"
        case "smart-bind-npm-install-cold":
            return "smart-bind-npm-install"
        case "strict-bind-pnpm-install-cold":
            return "strict-bind-pnpm-install"
        case "smart-bind-pnpm-install-cold":
            return "smart-bind-pnpm-install"
        case "strict-bind-cargo-build-cold":
            return "strict-bind-cargo-build"
        case "smart-bind-cargo-build-cold":
            return "smart-bind-cargo-build"
        case "volume-npm-install-cold":
            return "volume-npm-install"
        case "volume-pnpm-install-cold":
            return "volume-pnpm-install"
        case "volume-cargo-build-cold":
            return "volume-cargo-build"
        case "conjetfs-npm-install-cold":
            return "conjetfs-npm-install"
        case "conjetfs-pnpm-install-cold":
            return "conjetfs-pnpm-install"
        case "conjetfs-cargo-build-cold":
            return "conjetfs-cargo-build"
        case "compose-up-cold":
            return "compose-up"
        default:
            return workload
        }
    }

    public var contexts: [String]
    public var iterations: Int
    public var warmup: Bool
    public var dockerExecutable: String
    public var workloads: [String]
    public var commandTimeoutSeconds: Double
    public var phase: BenchmarkSamplePhase
    public var resourceScope: String?

    private let runner: @Sendable (String, [String]) throws -> ProcessResult
    private let inputRunner: @Sendable (String, [String], Data?) throws -> ProcessResult

    public init(
        contexts: [String],
        iterations: Int = 1,
        warmup: Bool = false,
        samplePhase: BenchmarkSamplePhase? = nil,
        workloads: [String] = DockerBenchmarkSuite.defaultWorkloads,
        dockerExecutable: String = "/usr/bin/env",
        commandTimeoutSeconds: Double = 180,
        resourceScope: String? = nil,
        runner: (@Sendable (String, [String]) throws -> ProcessResult)? = nil,
        inputRunner: (@Sendable (String, [String], Data?) throws -> ProcessResult)? = nil
    ) {
        self.contexts = contexts
        self.iterations = max(1, iterations)
        self.warmup = warmup
        self.phase = samplePhase ?? (warmup ? .warm : .cold)
        self.workloads = workloads.isEmpty ? DockerBenchmarkSuite.defaultWorkloads : workloads
        self.dockerExecutable = dockerExecutable
        let timeout = max(1, commandTimeoutSeconds)
        self.commandTimeoutSeconds = timeout
        self.resourceScope = resourceScope.map { $0.sanitizedDockerTag }
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
        let requestedWorkloads = Set(workloads)
        let supportedWorkloads = Set(Self.supportedWorkloads)
        let unknownWorkloads = requestedWorkloads.subtracting(supportedWorkloads)
        guard unknownWorkloads.isEmpty else {
            throw ConjetError.invalidArgument(
                "unknown Docker benchmark workloads: \(unknownWorkloads.sorted().joined(separator: ", "))"
            )
        }
        let enabledWorkloads = Set(workloads.map(Self.canonicalWorkloadName))

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
        let conjetFSHome = workDirectory.appendingPathComponent(".conjetfs-home", isDirectory: true)
        var nodeModulesFileCount = 0
        var composeFile: URL?

        if enabledWorkloads.contains("image-build") {
            try prepareBuildContext(at: buildDirectory)
        }
        if enabledWorkloads.contains("copy-node-modules") {
            nodeModulesFileCount = try prepareNodeModulesCopyContext(at: nodeModulesCopyDirectory)
        }
        if enabledWorkloads.contains("npm-install") {
            try prepareNPMInstallContext(at: npmInstallDirectory)
        }
        if enabledWorkloads.contains("pnpm-install") {
            try preparePNPMInstallContext(at: pnpmInstallDirectory)
        }
        if enabledWorkloads.contains("cargo-build") {
            try prepareCargoBuildContext(at: cargoBuildDirectory)
        }
        if !enabledWorkloads.isDisjoint(with: ["strict-bind-npm-install", "smart-bind-npm-install"]) {
            try prepareNPMProject(at: bindNPMDirectory)
        }
        if !enabledWorkloads.isDisjoint(with: ["strict-bind-pnpm-install", "smart-bind-pnpm-install"]) {
            try preparePNPMProject(at: bindPNPMDirectory)
        }
        if !enabledWorkloads.isDisjoint(with: ["strict-bind-cargo-build", "smart-bind-cargo-build"]) {
            try prepareCargoProject(at: bindCargoDirectory)
        }
        if enabledWorkloads.contains("conjetfs-npm-install") {
            try prepareConjetFSNodeProject(at: conjetFSNPMDirectory, packageManager: .npm)
        }
        if enabledWorkloads.contains("conjetfs-pnpm-install") {
            try prepareConjetFSNodeProject(at: conjetFSPNPMDirectory, packageManager: .pnpm)
        }
        if enabledWorkloads.contains("conjetfs-cargo-build") {
            try prepareConjetFSCargoProject(at: conjetFSCargoDirectory)
        }
        if !enabledWorkloads.isDisjoint(with: ["strict-bind-hot-reload", "smart-bind-hot-reload"]) {
            try prepareHotReloadProject(at: bindHotReloadDirectory, token: "initial")
        }
        if enabledWorkloads.contains("conjetfs-hot-reload") {
            try prepareHotReloadProject(at: conjetFSHotReloadDirectory, token: "initial")
        }
        if enabledWorkloads.contains("compose-up") {
            composeFile = try prepareComposeProject(at: composeDirectory)
        }

        var results: [BenchmarkResult] = []
        for context in contexts {
            if shouldPrepullBaseImages {
                for image in warmupImages(for: enabledWorkloads) {
                    _ = try? runDocker(context: context, arguments: ["pull", image])
                }
            }
            if requiresPNPMBenchmarkImage(enabledWorkloads) {
                try ensurePNPMBenchmarkImage(context: context, workDirectory: workDirectory)
            }
            if warmup && requiresBuildKitWarmup(enabledWorkloads) {
                try warmupBuildKit(
                    context: context,
                    workDirectory: workDirectory,
                    images: buildKitWarmupImages(for: enabledWorkloads)
                )
                try warmupDockerBuildWorkloads(
                    context: context,
                    enabledWorkloads: enabledWorkloads,
                    npmInstallDirectory: npmInstallDirectory,
                    pnpmInstallDirectory: pnpmInstallDirectory,
                    cargoBuildDirectory: cargoBuildDirectory
                )
            }
            if warmup {
                try warmupConjetPackageCaches(
                    context: context,
                    enabledWorkloads: enabledWorkloads,
                    bindNPMDirectory: bindNPMDirectory,
                    bindPNPMDirectory: bindPNPMDirectory,
                    conjetFSNPMDirectory: conjetFSNPMDirectory,
                    conjetFSPNPMDirectory: conjetFSPNPMDirectory,
                    conjetFSCargoDirectory: conjetFSCargoDirectory,
                    homeDirectory: conjetFSHome
                )
            }

        }

        for iteration in 1...iterations {
            for context in contexts {
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
                    let imageTag = benchmarkResourceName(context, "image", String(iteration))
                    _ = try? runDocker(context: context, arguments: ["rmi", "-f", imageTag])
                    defer { _ = try? runDocker(context: context, arguments: ["rmi", "-f", imageTag]) }
                    results.append(try benchmark(
                        workload: "image-build",
                        context: context,
                        iteration: iteration,
                        arguments: buildArguments(["build", "-t", imageTag, buildDirectory.path]),
                        metrics: dockerBuildMetrics()
                    ))
                }

                if enabledWorkloads.contains("copy-node-modules") {
                    try updateNodeModulesCopyMarker(at: nodeModulesCopyDirectory, iteration: iteration)
                    let imageTag = benchmarkResourceName(context, "copy-node-modules", String(iteration))
                    _ = try? runDocker(context: context, arguments: ["rmi", "-f", imageTag])
                    defer { _ = try? runDocker(context: context, arguments: ["rmi", "-f", imageTag]) }
                    results.append(try benchmark(
                        workload: "copy-node-modules",
                        context: context,
                        iteration: iteration,
                        arguments: buildArguments(["build", "-t", imageTag, nodeModulesCopyDirectory.path]),
                        metrics: dockerBuildMetrics(["file_count": Double(nodeModulesFileCount)])
                    ))
                }

                if enabledWorkloads.contains("npm-install") {
                    let imageTag = benchmarkResourceName(context, "npm", String(iteration))
                    _ = try? runDocker(context: context, arguments: ["rmi", "-f", imageTag])
                    defer { _ = try? runDocker(context: context, arguments: ["rmi", "-f", imageTag]) }
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
                        metrics: dockerBuildMetrics(["dependency_count": 3])
                    ))
                }

                if enabledWorkloads.contains("pnpm-install") {
                    let imageTag = benchmarkResourceName(context, "pnpm", String(iteration))
                    _ = try? runDocker(context: context, arguments: ["rmi", "-f", imageTag])
                    defer { _ = try? runDocker(context: context, arguments: ["rmi", "-f", imageTag]) }
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
                        metrics: dockerBuildMetrics(["dependency_count": 3])
                    ))
                }

                if enabledWorkloads.contains("cargo-build") {
                    let imageTag = benchmarkResourceName(context, "cargo", String(iteration))
                    _ = try? runDocker(context: context, arguments: ["rmi", "-f", imageTag])
                    defer { _ = try? runDocker(context: context, arguments: ["rmi", "-f", imageTag]) }
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
                        metrics: dockerBuildMetrics(["dependency_count": 2])
                    ))
                }

                if enabledWorkloads.contains("strict-bind-npm-install") {
                    try resetNPMInstallArtifacts(at: bindNPMDirectory, preserveCaches: warmup)
                    results.append(try benchmark(
                        workload: "strict-bind-npm-install",
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
                        metrics: topologyMetrics(
                            topology: "strict-bind",
                            strictBind: true,
                            smartMount: false,
                            hostBindPaths: ["/app"],
                            extra: ["dependency_count": 3]
                        )
                    ))
                }

                if enabledWorkloads.contains("smart-bind-npm-install") {
                    try resetNPMInstallArtifacts(at: bindNPMDirectory, preserveCaches: warmup)
                    let overlay = nativeOverlayPlan(
                        context: context,
                        workload: "smart-bind-npm-install",
                        iteration: iteration,
                        targets: [
                            ("deps", "/app/node_modules")
                        ]
                    )
                    removeDockerVolumes(context: context, names: overlay.volumeNames)
                    defer { removeDockerVolumes(context: context, names: overlay.volumeNames) }
                    results.append(try benchmark(
                        workload: "smart-bind-npm-install",
                        context: context,
                        iteration: iteration,
                        arguments: [
                            "run",
                            "--rm",
                            "--mount",
                            "type=bind,source=\(bindNPMDirectory.path),target=/app",
                        ] + overlay.mountArguments + [
                            "-w",
                            "/app",
                            "node:22-alpine",
                            "sh",
                            "-c",
                            npmInstallCommand(guestPath: overlay.volumeNames.isEmpty ? "/app" : "/app/node_modules") + " && test -d node_modules/lodash"
                        ],
                        metrics: topologyMetrics(
                            topology: "smart-bind",
                            strictBind: false,
                            smartMount: true,
                            nativeOverlayMounts: overlay.volumeNames.count,
                            linuxNativeWritePaths: overlay.writePaths,
                            hostBindPaths: ["/app"],
                            extra: ["dependency_count": 3]
                        )
                    ))
                }

                if enabledWorkloads.contains("strict-bind-pnpm-install") {
                    try resetPNPMInstallArtifacts(at: bindPNPMDirectory, preserveCaches: warmup)
                    results.append(try benchmark(
                        workload: "strict-bind-pnpm-install",
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
                        metrics: topologyMetrics(
                            topology: "strict-bind",
                            strictBind: true,
                            smartMount: false,
                            hostBindPaths: ["/app"],
                            extra: ["dependency_count": 3]
                        )
                    ))
                }

                if enabledWorkloads.contains("smart-bind-pnpm-install") {
                    try resetPNPMInstallArtifacts(at: bindPNPMDirectory, preserveCaches: warmup)
                    let overlay = nativeOverlayPlan(
                        context: context,
                        workload: "smart-bind-pnpm-install",
                        iteration: iteration,
                        targets: [
                            ("deps", "/app/node_modules")
                        ]
                    )
                    removeDockerVolumes(context: context, names: overlay.volumeNames)
                    defer { removeDockerVolumes(context: context, names: overlay.volumeNames) }
                    results.append(try benchmark(
                        workload: "smart-bind-pnpm-install",
                        context: context,
                        iteration: iteration,
                        arguments: [
                            "run",
                            "--rm",
                            "--mount",
                            "type=bind,source=\(bindPNPMDirectory.path),target=/app",
                        ] + overlay.mountArguments + [
                            "-w",
                            "/app",
                            Self.pnpmBenchmarkImage,
                            "sh",
                            "-c",
                            pnpmInstallCommand(guestPath: overlay.volumeNames.isEmpty ? "/app" : "/app/node_modules") + " && test -d node_modules/lodash"
                        ],
                        metrics: topologyMetrics(
                            topology: "smart-bind",
                            strictBind: false,
                            smartMount: true,
                            nativeOverlayMounts: overlay.volumeNames.count,
                            linuxNativeWritePaths: overlay.writePaths,
                            hostBindPaths: ["/app"],
                            extra: ["dependency_count": 3]
                        )
                    ))
                }

                if enabledWorkloads.contains("volume-npm-install") {
                    let volumeName = benchmarkResourceName(context, "npm-volume", String(iteration))
                    _ = try? runDocker(context: context, arguments: ["volume", "rm", "-f", volumeName])
                    defer { _ = try? runDocker(context: context, arguments: ["volume", "rm", "-f", volumeName]) }
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
                        metrics: topologyMetrics(
                            topology: "volume",
                            strictBind: false,
                            smartMount: false,
                            nativeOverlayMounts: 1,
                            linuxNativeWritePaths: ["/app"],
                            extra: ["dependency_count": 3]
                        )
                    ))
                }

                if enabledWorkloads.contains("volume-pnpm-install") {
                    let volumeName = benchmarkResourceName(context, "pnpm-volume", String(iteration))
                    _ = try? runDocker(context: context, arguments: ["volume", "rm", "-f", volumeName])
                    defer { _ = try? runDocker(context: context, arguments: ["volume", "rm", "-f", volumeName]) }
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
                        metrics: topologyMetrics(
                            topology: "volume",
                            strictBind: false,
                            smartMount: false,
                            nativeOverlayMounts: 1,
                            linuxNativeWritePaths: ["/app"],
                            extra: ["dependency_count": 3]
                        )
                    ))
                }

                if enabledWorkloads.contains("strict-bind-cargo-build") {
                    try resetCargoBuildArtifacts(at: bindCargoDirectory)
                    results.append(try benchmark(
                        workload: "strict-bind-cargo-build",
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
                        metrics: topologyMetrics(
                            topology: "strict-bind",
                            strictBind: true,
                            smartMount: false,
                            hostBindPaths: ["/app"],
                            extra: ["dependency_count": 2]
                        )
                    ))
                }

                if enabledWorkloads.contains("smart-bind-cargo-build") {
                    try resetCargoBuildArtifacts(at: bindCargoDirectory)
                    let overlay = nativeOverlayPlan(
                        context: context,
                        workload: "smart-bind-cargo-build",
                        iteration: iteration,
                        targets: [
                            ("target", "/app/target")
                        ]
                    )
                    removeDockerVolumes(context: context, names: overlay.volumeNames)
                    defer { removeDockerVolumes(context: context, names: overlay.volumeNames) }
                    let cargoCommand = "export CARGO_HOME=/app/target/.cargo-home CARGO_TARGET_DIR=/app/target && mkdir -p /app/target/.cargo-home && cargo build --release && test -x /app/target/release/conjet-cargo-build-benchmark"
                    results.append(try benchmark(
                        workload: "smart-bind-cargo-build",
                        context: context,
                        iteration: iteration,
                        arguments: [
                            "run",
                            "--rm",
                            "--mount",
                            "type=bind,source=\(bindCargoDirectory.path),target=/app",
                        ] + overlay.mountArguments + [
                            "-w",
                            "/app",
                            "rust:1-alpine",
                            "sh",
                            "-c",
                            cargoCommand
                        ],
                        metrics: topologyMetrics(
                            topology: "smart-bind",
                            strictBind: false,
                            smartMount: true,
                            nativeOverlayMounts: overlay.volumeNames.count,
                            linuxNativeWritePaths: overlay.writePaths,
                            hostBindPaths: ["/app"],
                            extra: ["dependency_count": 2]
                        )
                    ))
                }

                if enabledWorkloads.contains("volume-cargo-build") {
                    let volumeName = benchmarkResourceName(context, "cargo-volume", String(iteration))
                    _ = try? runDocker(context: context, arguments: ["volume", "rm", "-f", volumeName])
                    defer { _ = try? runDocker(context: context, arguments: ["volume", "rm", "-f", volumeName]) }
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
                        metrics: topologyMetrics(
                            topology: "volume",
                            strictBind: false,
                            smartMount: false,
                            nativeOverlayMounts: 1,
                            linuxNativeWritePaths: ["/app"],
                            extra: ["dependency_count": 2]
                        )
                    ))
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
                        metrics: topologyMetrics(
                            topology: "conjetfs",
                            strictBind: false,
                            smartMount: false,
                            nativeOverlayMounts: 1,
                            linuxNativeWritePaths: ["/workspace"],
                            conjetfsFastPath: true,
                            extra: ["dependency_count": 3]
                        )
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
                        metrics: topologyMetrics(
                            topology: "conjetfs",
                            strictBind: false,
                            smartMount: false,
                            nativeOverlayMounts: 1,
                            linuxNativeWritePaths: ["/workspace"],
                            conjetfsFastPath: true,
                            extra: ["dependency_count": 3]
                        )
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
                        resetProjectVolume: !warmup,
                        metrics: topologyMetrics(
                            topology: "conjetfs",
                            strictBind: false,
                            smartMount: false,
                            nativeOverlayMounts: 1,
                            linuxNativeWritePaths: ["/workspace"],
                            conjetfsFastPath: true,
                            extra: [
                            "dependency_count": 2,
                            "vm_native_target_reused": warmup ? 1 : 0
                            ]
                        )
                    ))
                }

                if enabledWorkloads.contains("strict-bind-hot-reload") {
                    try resetHotReloadProject(at: bindHotReloadDirectory)
                    try prepareHotReloadProject(at: bindHotReloadDirectory, token: "initial-\(iteration)")
                    results.append(benchmarkBindHotReload(
                        workload: "strict-bind-hot-reload",
                        context: context,
                        iteration: iteration,
                        projectDirectory: bindHotReloadDirectory,
                        smartOverlay: false
                    ))
                }

                if enabledWorkloads.contains("smart-bind-hot-reload") {
                    try resetHotReloadProject(at: bindHotReloadDirectory)
                    try prepareHotReloadProject(at: bindHotReloadDirectory, token: "initial-\(iteration)")
                    results.append(benchmarkBindHotReload(
                        workload: "smart-bind-hot-reload",
                        context: context,
                        iteration: iteration,
                        projectDirectory: bindHotReloadDirectory,
                        smartOverlay: true
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
                    let volumeName = benchmarkResourceName(context, "volume", String(iteration))
                    _ = try? runDocker(context: context, arguments: ["volume", "rm", "-f", volumeName])
                    defer { _ = try? runDocker(context: context, arguments: ["volume", "rm", "-f", volumeName]) }
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
                        metrics: topologyMetrics(
                            topology: "named-volume",
                            strictBind: false,
                            smartMount: false,
                            nativeOverlayMounts: 1,
                            linuxNativeWritePaths: ["/data"],
                            extra: ["file_count": 300]
                        )
                    ))
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
                        metrics: topologyMetrics(
                            topology: "tmpfs",
                            strictBind: false,
                            smartMount: false,
                            linuxNativeWritePaths: ["/scratch"],
                            extra: ["file_count": 300]
                        )
                    ))
                }

                if enabledWorkloads.contains("compose-up"), let composeFile {
                    let project = benchmarkResourceName(context, String(iteration))
                    let downArguments = [
                        "compose",
                        "-f",
                        composeFile.path,
                        "-p",
                        project,
                        "down",
                        "-v",
                        "--remove-orphans"
                    ]
                    _ = try? runDocker(context: context, arguments: downArguments)
                    defer { _ = try? runDocker(context: context, arguments: downArguments) }
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
                }
            }
        }

        return results
    }

    private var samplePhase: BenchmarkSamplePhase {
        phase
    }

    private func benchmarkResourceName(_ components: String...) -> String {
        var parts = ["conjet-bench"]
        if let resourceScope {
            parts.append(resourceScope)
        }
        parts.append(contentsOf: components.map(\.sanitizedDockerTag))
        return parts.joined(separator: "-")
    }

    private func buildArguments(_ arguments: [String]) -> [String] {
        guard shouldDisableDockerBuildCache, arguments.first == "build" else {
            return arguments
        }
        return ["build", "--no-cache"] + arguments.dropFirst()
    }

    private var shouldDisableDockerBuildCache: Bool {
        phase != .warm
    }

    private var shouldPrepullBaseImages: Bool {
        phase != .trueCold
    }

    private func requiresPNPMBenchmarkImage(_ workloads: Set<String>) -> Bool {
        !workloads.isDisjoint(with: [
            "pnpm-install",
            "strict-bind-pnpm-install",
            "smart-bind-pnpm-install",
            "volume-pnpm-install",
            "conjetfs-pnpm-install"
        ])
    }

    private func requiresBuildKitWarmup(_ workloads: Set<String>) -> Bool {
        !workloads.isDisjoint(with: [
            "image-build",
            "copy-node-modules",
            "npm-install",
            "pnpm-install",
            "cargo-build"
        ])
    }

    private func buildKitWarmupImages(for workloads: Set<String>) -> [String] {
        var images: [String] = []
        if !workloads.isDisjoint(with: ["image-build", "copy-node-modules"]) {
            images.append("alpine:3.20")
        }
        if !workloads.isDisjoint(with: ["npm-install"]) {
            images.append("node:22-alpine")
        }
        if !workloads.isDisjoint(with: ["pnpm-install"]) {
            images.append(Self.pnpmBenchmarkImage)
        }
        if !workloads.isDisjoint(with: ["cargo-build"]) {
            images.append("rust:1-alpine")
        }
        return Array(Set(images)).sorted()
    }

    private func warmupBuildKit(context: String, workDirectory: URL, images: [String]) throws {
        guard !images.isEmpty else { return }
        let directory = workDirectory
            .appendingPathComponent("buildkit-warmup-\(context.sanitizedDockerTag)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for image in images {
            let dockerfile = """
            FROM \(image)
            RUN true
            """
            try dockerfile.write(
                to: directory.appendingPathComponent("Dockerfile"),
                atomically: true,
                encoding: .utf8
            )
            let imageTag = benchmarkResourceName(context, "buildkit", image)
            _ = try? runDocker(context: context, arguments: ["rmi", "-f", imageTag])
            defer { _ = try? runDocker(context: context, arguments: ["rmi", "-f", imageTag]) }
            let result = try runDocker(context: context, arguments: [
                "build",
                "--no-cache",
                "-q",
                "-t",
                imageTag,
                directory.path
            ])
            if !result.succeeded {
                throw ConjetError.processFailed(
                    executable: dockerExecutable,
                    exitCode: result.exitCode,
                    stderr: result.stderr.isEmpty ? result.stdout : result.stderr
                )
            }
        }
    }

    private func warmupDockerBuildWorkloads(
        context: String,
        enabledWorkloads: Set<String>,
        npmInstallDirectory: URL,
        pnpmInstallDirectory: URL,
        cargoBuildDirectory: URL
    ) throws {
        if enabledWorkloads.contains("npm-install") {
            try warmupDockerBuildWorkload(
                context: context,
                imageTag: benchmarkResourceName(context, "npm", "warmup"),
                directory: npmInstallDirectory
            )
        }
        if enabledWorkloads.contains("pnpm-install") {
            try warmupDockerBuildWorkload(
                context: context,
                imageTag: benchmarkResourceName(context, "pnpm", "warmup"),
                directory: pnpmInstallDirectory
            )
        }
        if enabledWorkloads.contains("cargo-build") {
            try warmupDockerBuildWorkload(
                context: context,
                imageTag: benchmarkResourceName(context, "cargo", "warmup"),
                directory: cargoBuildDirectory
            )
        }
    }

    private func warmupDockerBuildWorkload(context: String, imageTag: String, directory: URL) throws {
        _ = try? runDocker(context: context, arguments: ["rmi", "-f", imageTag])
        defer { _ = try? runDocker(context: context, arguments: ["rmi", "-f", imageTag]) }
        let result = try runDocker(context: context, arguments: [
            "build",
            "--build-arg",
            "CONJET_BENCH_ITERATION=0",
            "-t",
            imageTag,
            directory.path
        ])
        if !result.succeeded {
            throw ConjetError.processFailed(
                executable: dockerExecutable,
                exitCode: result.exitCode,
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
    }

    private func ensurePNPMBenchmarkImage(context: String, workDirectory: URL) throws {
        Self.pnpmBenchmarkImageLock.lock()
        defer { Self.pnpmBenchmarkImageLock.unlock() }

        if (try? runDocker(context: context, arguments: ["image", "inspect", Self.pnpmBenchmarkImage]))?.succeeded == true {
            return
        }

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

    private func commonMetrics(_ metrics: [String: Double], iteration: Int) -> BenchmarkMetrics {
        commonMetrics(BenchmarkMetrics(metrics), iteration: iteration)
    }

    private func commonMetrics(_ metrics: BenchmarkMetrics, iteration: Int) -> BenchmarkMetrics {
        var result = metrics
        result["iteration"] = Double(iteration)
        result[BenchmarkSamplePhase.metricKey] = samplePhase.metricValue ?? -1
        result["benchmark_warmup"] = warmup ? 1 : 0
        result.setString(samplePhase.rawValue, for: "sample_phase")
        result.setString(samplePhase.buildCacheMode, for: "build_cache_mode")
        result.setString(samplePhase.imageCacheMode, for: "image_cache_mode")
        result.setString(samplePhase.networkCacheMode, for: "network_cache_mode")
        result.setBool(shouldPrepullBaseImages, for: "base_image_prepulled")
        if result.value(for: "mount_topology") == nil {
            result.setString("unknown", for: "mount_topology")
        }
        if result.value(for: "strict_bind") == nil {
            result.setBool(false, for: "strict_bind")
        }
        if result.value(for: "smart_mount") == nil {
            result.setBool(false, for: "smart_mount")
        }
        if result.value(for: "native_overlay_mounts") == nil {
            result["native_overlay_mounts"] = 0
        }
        if result.value(for: "linux_native_write_paths") == nil {
            result.setStringArray([], for: "linux_native_write_paths")
        }
        if result.value(for: "host_bind_paths") == nil {
            result.setStringArray([], for: "host_bind_paths")
        }
        if result.value(for: "conjetfs_fast_path") == nil {
            result.setBool(false, for: "conjetfs_fast_path")
        }
        return result
    }

    private func topologyMetrics(
        topology: String,
        strictBind: Bool,
        smartMount: Bool,
        nativeOverlayMounts: Int = 0,
        linuxNativeWritePaths: [String] = [],
        hostBindPaths: [String] = [],
        conjetfsFastPath: Bool = false,
        extra: [String: Double] = [:]
    ) -> BenchmarkMetrics {
        var metrics = BenchmarkMetrics(extra)
        metrics.setString(topology, for: "mount_topology")
        metrics.setBool(strictBind, for: "strict_bind")
        metrics.setBool(smartMount, for: "smart_mount")
        metrics["native_overlay_mounts"] = Double(nativeOverlayMounts)
        metrics.setStringArray(linuxNativeWritePaths, for: "linux_native_write_paths")
        metrics.setStringArray(hostBindPaths, for: "host_bind_paths")
        metrics.setBool(conjetfsFastPath, for: "conjetfs_fast_path")
        metrics["bind_native_overlay_mounts"] = Double(nativeOverlayMounts)
        return metrics
    }

    private func dockerBuildMetrics(_ extra: [String: Double] = [:]) -> BenchmarkMetrics {
        var metrics = topologyMetrics(topology: "image-build", strictBind: false, smartMount: false, extra: extra)
        metrics.setBool(shouldDisableDockerBuildCache, for: "docker_build_no_cache")
        metrics.setNull(for: "buildkit_cached_steps_detected")
        metrics.setNull(for: "buildkit_cache_hit_count")
        metrics.setNull(for: "buildkit_cache_miss_count")
        return metrics
    }

    private func warmupConjetPackageCaches(
        context: String,
        enabledWorkloads: Set<String>,
        bindNPMDirectory: URL,
        bindPNPMDirectory: URL,
        conjetFSNPMDirectory: URL,
        conjetFSPNPMDirectory: URL,
        conjetFSCargoDirectory: URL,
        homeDirectory: URL
    ) throws {
        if !enabledWorkloads.isDisjoint(with: ["strict-bind-npm-install", "smart-bind-npm-install"]) {
            try resetNPMInstallArtifacts(at: bindNPMDirectory, preserveCaches: false)
            try prepareNPMProject(at: bindNPMDirectory)
            _ = try? benchmark(
                workload: "smart-bind-npm-install",
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

        if !enabledWorkloads.isDisjoint(with: ["strict-bind-pnpm-install", "smart-bind-pnpm-install"]) {
            try resetPNPMInstallArtifacts(at: bindPNPMDirectory, preserveCaches: false)
            try preparePNPMProject(at: bindPNPMDirectory)
            _ = try? benchmark(
                workload: "smart-bind-pnpm-install",
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

        if enabledWorkloads.contains("conjetfs-cargo-build") {
            try resetConjetFSProject(at: conjetFSCargoDirectory)
            try prepareConjetFSCargoProject(at: conjetFSCargoDirectory)
            _ = benchmarkConjetFSProject(
                workload: "conjetfs-cargo-build",
                context: context,
                iteration: 0,
                projectDirectory: conjetFSCargoDirectory,
                homeDirectory: homeDirectory,
                image: "rust:1-alpine",
                shellCommand: "cargo build --release && test -x target/release/conjet-cargo-build-benchmark",
                usePackageCaches: false,
                resetProjectVolume: true,
                metrics: [
                    "dependency_count": 2,
                    "benchmark_warmup_sample": 1,
                    "vm_native_target_warmup": 1
                ]
            )
        }
    }

    private func benchmark(
        workload: String,
        context: String,
        iteration: Int,
        arguments: [String],
        metrics: BenchmarkMetrics = [:]
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
        metrics: BenchmarkMetrics
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
        workload: String,
        context: String,
        iteration: Int,
        projectDirectory: URL,
        smartOverlay: Bool
    ) -> BenchmarkResult {
        let containerName = benchmarkResourceName(context, workload, String(iteration))
        let token = "hot-\(context.sanitizedDockerTag)-\(iteration)-\(UUID().uuidString.prefix(8))"
        let overlay = smartOverlay
            ? nativeOverlayPlan(
                context: context,
                workload: workload,
                iteration: iteration,
                targets: [("deps", "/app/node_modules")]
            )
            : .empty
        removeDockerVolumes(context: context, names: overlay.volumeNames)
        let runArguments = [
            "run",
            "-d",
            "--name",
            containerName,
            "--mount",
            "type=bind,source=\(projectDirectory.path),target=/app",
        ] + overlay.mountArguments + [
            "-w",
            "/app",
            "node:22-alpine",
            "node",
            "-e",
            hotReloadWatchScript(path: "/app/src/hot.txt", token: token)
        ]
        return benchmarkHotReload(
            workload: workload,
            context: context,
            iteration: iteration,
            runArguments: runArguments,
            containerName: containerName,
            token: token,
            hotFile: projectDirectory.appendingPathComponent("src/hot.txt"),
            metrics: topologyMetrics(
                topology: smartOverlay ? "smart-bind" : "strict-bind",
                strictBind: !smartOverlay,
                smartMount: smartOverlay,
                nativeOverlayMounts: overlay.volumeNames.count,
                linuxNativeWritePaths: overlay.writePaths,
                hostBindPaths: ["/app"]
            ),
            cleanupVolumes: overlay.volumeNames
        )
    }

    private func benchmarkConjetFSHotReload(
        context: String,
        iteration: Int,
        projectDirectory: URL,
        homeDirectory: URL
    ) -> BenchmarkResult {
        let containerName = benchmarkResourceName(context, "conjetfs-hot", String(iteration))
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
        defer { _ = try? runDocker(context: context, arguments: ["rm", "-f", containerName]) }
        var metrics = commonMetrics(
            topologyMetrics(
                topology: "conjetfs",
                strictBind: false,
                smartMount: false,
                nativeOverlayMounts: 1,
                linuxNativeWritePaths: ["/workspace"],
                conjetfsFastPath: true
            ),
            iteration: iteration
        )
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
        hotFile: URL,
        metrics initialMetrics: BenchmarkMetrics = [:],
        cleanupVolumes: [String] = []
    ) -> BenchmarkResult {
        let machine = MachineProfiler.capture()
        let command = dockerArguments(context: context, arguments: runArguments)
        _ = try? runDocker(context: context, arguments: ["rm", "-f", containerName])
        defer {
            _ = try? runDocker(context: context, arguments: ["rm", "-f", containerName])
            removeDockerVolumes(context: context, names: cleanupVolumes)
        }
        let startedAt = Date()
        var metrics = commonMetrics(initialMetrics, iteration: iteration)
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
        COPY deps ./deps
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
        let intfmtDirectory = directory.appendingPathComponent("deps/conjet_intfmt/src", isDirectory: true)
        let floatfmtDirectory = directory.appendingPathComponent("deps/conjet_floatfmt/src", isDirectory: true)
        try FileManager.default.createDirectory(at: intfmtDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: floatfmtDirectory, withIntermediateDirectories: true)

        let cargoToml = """
        [package]
        name = "conjet-cargo-build-benchmark"
        version = "0.1.0"
        edition = "2021"

        [dependencies]
        conjet_intfmt = { path = "deps/conjet_intfmt" }
        conjet_floatfmt = { path = "deps/conjet_floatfmt" }
        """
        try cargoToml.write(
            to: directory.appendingPathComponent("Cargo.toml"),
            atomically: true,
            encoding: .utf8
        )
        try """
        [package]
        name = "conjet_intfmt"
        version = "0.1.0"
        edition = "2021"
        """.write(
            to: directory.appendingPathComponent("deps/conjet_intfmt/Cargo.toml"),
            atomically: true,
            encoding: .utf8
        )
        try """
        pub fn render(value: u64) -> String {
            let mut n = value;
            let mut digits = [0u8; 20];
            let mut index = digits.len();
            if n == 0 {
                index -= 1;
                digits[index] = b'0';
            }
            while n > 0 {
                index -= 1;
                digits[index] = b'0' + (n % 10) as u8;
                n /= 10;
            }
            String::from_utf8(digits[index..].to_vec()).expect("ascii digits")
        }
        """.write(
            to: intfmtDirectory.appendingPathComponent("lib.rs"),
            atomically: true,
            encoding: .utf8
        )
        try """
        [package]
        name = "conjet_floatfmt"
        version = "0.1.0"
        edition = "2021"
        """.write(
            to: directory.appendingPathComponent("deps/conjet_floatfmt/Cargo.toml"),
            atomically: true,
            encoding: .utf8
        )
        try """
        pub fn render(value: f64) -> String {
            let scaled = (value * 1000.0).round() as i64;
            let whole = scaled / 1000;
            let fraction = (scaled.abs() % 1000) as u64;
            format!("{whole}.{fraction:03}")
        }
        """.write(
            to: floatfmtDirectory.appendingPathComponent("lib.rs"),
            atomically: true,
            encoding: .utf8
        )

        let main = """
        fn main() {
            println!("{} {}", conjet_intfmt::render(42), conjet_floatfmt::render(3.14159));
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
        if !workloads.isDisjoint(with: [
            "npm-install",
            "pnpm-install",
            "strict-bind-npm-install",
            "strict-bind-pnpm-install",
            "smart-bind-npm-install",
            "smart-bind-pnpm-install",
            "volume-npm-install",
            "volume-pnpm-install",
            "conjetfs-npm-install",
            "conjetfs-pnpm-install",
            "strict-bind-hot-reload",
            "smart-bind-hot-reload",
            "conjetfs-hot-reload"
        ]) {
            images.append("node:22-alpine")
        }
        if !workloads.isDisjoint(with: [
            "cargo-build",
            "strict-bind-cargo-build",
            "smart-bind-cargo-build",
            "volume-cargo-build",
            "conjetfs-cargo-build"
        ]) {
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
        for name in ["target"] {
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

    private func nativeOverlayPlan(
        context: String,
        workload: String,
        iteration: Int,
        targets: [(String, String)]
    ) -> BindNativeOverlayPlan {
        let pairs: [(String, String)] = targets.map { pair in
            let suffix = pair.0
            let target = pair.1
            return (
                benchmarkResourceName(context, workload, suffix, String(iteration)),
                target
            )
        }
        return BindNativeOverlayPlan(
            mountArguments: pairs.flatMap { pair in
                let name = pair.0
                let target = pair.1
                return [
                    "--mount",
                    "type=volume,source=\(name),target=\(target)"
                ]
            },
            volumeNames: pairs.map { $0.0 },
            writePaths: pairs.map { $0.1 }
        )
    }

    private func removeDockerVolumes(context: String, names: [String]) {
        guard !names.isEmpty else { return }
        for name in names {
            _ = try? runDocker(context: context, arguments: ["volume", "rm", "-f", name])
        }
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
        mkdir -p src deps/conjet_intfmt/src deps/conjet_floatfmt/src
        cat > Cargo.toml <<'TOML'
        [package]
        name = "conjet-cargo-build-benchmark"
        version = "0.1.0"
        edition = "2021"

        [dependencies]
        conjet_intfmt = { path = "deps/conjet_intfmt" }
        conjet_floatfmt = { path = "deps/conjet_floatfmt" }
        TOML
        cat > deps/conjet_intfmt/Cargo.toml <<'TOML'
        [package]
        name = "conjet_intfmt"
        version = "0.1.0"
        edition = "2021"
        TOML
        cat > deps/conjet_intfmt/src/lib.rs <<'RS'
        pub fn render(value: u64) -> String {
            let mut n = value;
            let mut digits = [0u8; 20];
            let mut index = digits.len();
            if n == 0 {
                index -= 1;
                digits[index] = b'0';
            }
            while n > 0 {
                index -= 1;
                digits[index] = b'0' + (n % 10) as u8;
                n /= 10;
            }
            String::from_utf8(digits[index..].to_vec()).expect("ascii digits")
        }
        RS
        cat > deps/conjet_floatfmt/Cargo.toml <<'TOML'
        [package]
        name = "conjet_floatfmt"
        version = "0.1.0"
        edition = "2021"
        TOML
        cat > deps/conjet_floatfmt/src/lib.rs <<'RS'
        pub fn render(value: f64) -> String {
            let scaled = (value * 1000.0).round() as i64;
            let whole = scaled / 1000;
            let fraction = (scaled.abs() % 1000) as u64;
            format!("{whole}.{fraction:03}")
        }
        RS
        cat > src/main.rs <<'RS'
        fn main() {
            println!("{} {}", conjet_intfmt::render(42), conjet_floatfmt::render(3.14159));
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

import ConjetAppCore
import ConjetCore
import Foundation

public struct AppUIBenchmarkOptions: Sendable {
    public var samples: Int
    public var containerCount: Int
    public var imageCount: Int
    public var volumeCount: Int
    public var runningContainerCount: Int
    public var simulatedCommandLatencyMilliseconds: Double
    public var targetMilliseconds: Double

    public init(
        samples: Int = 20,
        containerCount: Int = 64,
        imageCount: Int = 32,
        volumeCount: Int = 32,
        runningContainerCount: Int = 12,
        simulatedCommandLatencyMilliseconds: Double = 0,
        targetMilliseconds: Double = 150
    ) {
        self.samples = max(1, samples)
        self.containerCount = max(0, containerCount)
        self.imageCount = max(0, imageCount)
        self.volumeCount = max(0, volumeCount)
        self.runningContainerCount = max(0, min(runningContainerCount, containerCount))
        self.simulatedCommandLatencyMilliseconds = max(0, simulatedCommandLatencyMilliseconds)
        self.targetMilliseconds = max(1, targetMilliseconds)
    }
}

public struct AppUIBenchmarkSuite: Sendable {
    private let options: AppUIBenchmarkOptions

    public init(options: AppUIBenchmarkOptions = AppUIBenchmarkOptions()) {
        self.options = options
    }

    public func run(outputDirectory: URL) throws -> [BenchmarkResult] {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var results: [BenchmarkResult] = []
        for sample in 0..<options.samples {
            results.append(try measure(workload: "ui-refresh-snapshot-full", sample: sample, outputDirectory: outputDirectory) { service in
                let snapshot = await service.loadSnapshot()
                var metrics = self.baseMetrics()
                metrics["container_count"] = Double(snapshot.containers.count)
                metrics["image_count"] = Double(snapshot.images.count)
                metrics["volume_count"] = Double(snapshot.volumes.count)
                metrics["stats_count"] = Double(snapshot.stats.count)
                metrics["process_count"] = Double(snapshot.containerProcesses.count)
                metrics.setBool(snapshot.dockerReachable, for: "docker_reachable")
                return AppUIBenchmarkOutcome(metrics: metrics, stdout: "full snapshot")
            })
            results.append(try measure(workload: "ui-list-containers", sample: sample, outputDirectory: outputDirectory) { service in
                let containers = await service.loadContainers()
                var metrics = self.baseMetrics()
                metrics["container_count"] = Double(containers.count)
                metrics["running_container_count"] = Double(containers.filter(\.isRunning).count)
                return AppUIBenchmarkOutcome(metrics: metrics, stdout: "containers \(containers.count)")
            })
            results.append(try measure(workload: "ui-list-images", sample: sample, outputDirectory: outputDirectory) { service in
                let images = await service.loadImages()
                var metrics = self.baseMetrics()
                metrics["image_count"] = Double(images.count)
                return AppUIBenchmarkOutcome(metrics: metrics, stdout: "images \(images.count)")
            })
            results.append(try measure(workload: "ui-list-volumes-fast", sample: sample, outputDirectory: outputDirectory) { service in
                let volumes = await service.loadVolumes(includeUsage: false)
                var metrics = self.baseMetrics()
                metrics["volume_count"] = Double(volumes.count)
                metrics.setBool(false, for: "volume_usage_enriched")
                return AppUIBenchmarkOutcome(metrics: metrics, stdout: "volumes \(volumes.count)")
            })
            results.append(try measure(workload: "ui-list-volumes-with-usage", sample: sample, outputDirectory: outputDirectory) { service in
                let volumes = await service.loadVolumes(includeUsage: true)
                var metrics = self.baseMetrics()
                metrics["volume_count"] = Double(volumes.count)
                metrics.setBool(true, for: "volume_usage_enriched")
                metrics["volume_size_count"] = Double(volumes.filter { !$0.size.isEmpty }.count)
                return AppUIBenchmarkOutcome(metrics: metrics, stdout: "volumes with usage \(volumes.count)")
            })
            results.append(try measure(workload: "ui-docker-start-command", sample: sample, outputDirectory: outputDirectory) { service in
                let entry = await service.runDocker(["start", "container-0"], label: "Start container-0", timeoutSeconds: 60)
                var metrics = self.baseMetrics()
                metrics.setBool(entry.succeeded, for: "command_succeeded")
                metrics["command_duration_ms"] = entry.duration * 1_000
                return AppUIBenchmarkOutcome(metrics: metrics, stdout: entry.stdout)
            })
            results.append(try measure(workload: "ui-vm-start-command", sample: sample, outputDirectory: outputDirectory) { service in
                let entry = await service.runConjet(["vm", "start", "--json"], label: "VM start", timeoutSeconds: nil)
                var metrics = self.baseMetrics()
                metrics.setBool(entry.succeeded, for: "command_succeeded")
                metrics["command_duration_ms"] = entry.duration * 1_000
                return AppUIBenchmarkOutcome(metrics: metrics, stdout: entry.stdout)
            })
        }
        return results
    }

    private func measure(
        workload: String,
        sample: Int,
        outputDirectory: URL,
        operation: @escaping @Sendable (ConjetManagementService) async -> AppUIBenchmarkOutcome
    ) throws -> BenchmarkResult {
        let paths = ConjetPaths(
            home: outputDirectory
                .appendingPathComponent("work", isDirectory: true)
                .appendingPathComponent("\(workload)-\(sample)", isDirectory: true)
        )
        try paths.ensureBaseDirectories()
        FileManager.default.createFile(atPath: paths.dockerSocket.path, contents: Data())
        let executor = AppUIBenchmarkExecutor(options: options, paths: paths)
        let tool = ResolvedTool(executable: "/tmp/conjet-app-ui-benchmark-tool", source: "app-ui-benchmark")
        let service = ConjetManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path],
            conjetTool: tool,
            conjetCoreTool: tool,
            dockerTool: tool,
            includeLaunchdEnvironment: false,
            executor: executor
        )
        let startedAt = Date()
        var outcome = awaitValue {
            await operation(service)
        }
        let duration = Date().timeIntervalSince(startedAt)
        let invocations = awaitValue {
            await executor.invocations
        }
        outcome.metrics["duration_ms"] = duration * 1_000
        outcome.metrics["command_invocations"] = Double(invocations.count)
        outcome.metrics.setBool(duration * 1_000 <= options.targetMilliseconds, for: "under_target")
        return BenchmarkResult(
            workload: workload,
            runtime: "conjet-swiftui",
            traceID: "app-ui-\(workload)-\(sample)",
            command: ["conjet-bench", "app-ui", workload],
            startedAt: startedAt,
            durationSeconds: duration,
            exitCode: 0,
            metrics: outcome.metrics,
            machine: MachineProfiler.capture(cacheTTLSeconds: 60),
            stdoutTail: outcome.stdout
        )
    }

    private func baseMetrics() -> BenchmarkMetrics {
        var metrics = BenchmarkMetrics()
        metrics["target_ms"] = options.targetMilliseconds
        metrics["simulated_command_latency_ms"] = options.simulatedCommandLatencyMilliseconds
        metrics["fixture_container_count"] = Double(options.containerCount)
        metrics["fixture_image_count"] = Double(options.imageCount)
        metrics["fixture_volume_count"] = Double(options.volumeCount)
        return metrics
    }
}

private struct AppUIBenchmarkOutcome: Sendable {
    var metrics: BenchmarkMetrics
    var stdout: String
}

private actor AppUIBenchmarkExecutor: CommandExecuting {
    private var recordedInvocations: [CommandInvocation] = []
    private let options: AppUIBenchmarkOptions
    private let paths: ConjetPaths

    init(options: AppUIBenchmarkOptions, paths: ConjetPaths) {
        self.options = options
        self.paths = paths
    }

    var invocations: [CommandInvocation] { recordedInvocations }

    func run(_ invocation: CommandInvocation) async -> ProcessResult {
        recordedInvocations.append(invocation)
        if options.simulatedCommandLatencyMilliseconds > 0 {
            let nanos = UInt64(options.simulatedCommandLatencyMilliseconds * 1_000_000)
            try? await Task.sleep(nanoseconds: nanos)
        }
        return response(for: invocation)
    }

    private func response(for invocation: CommandInvocation) -> ProcessResult {
        let arguments = invocation.arguments
        if arguments == ["status", "--json"] {
            return processResult(invocation, stdout: #"{"ok":false,"message":"benchmark daemon unavailable"}"#)
        }
        if arguments == ["profile", "list", "--json"] {
            return processResult(invocation, stdout: #"["default","dev"]"#)
        }
        if arguments.contains("ps") && arguments.contains("-a") {
            return processResult(invocation, stdout: dockerContainersJSONLines())
        }
        if arguments.contains("images") {
            return processResult(invocation, stdout: dockerImagesJSONLines())
        }
        if arguments.contains("volume") && arguments.contains("ls") {
            return processResult(invocation, stdout: dockerVolumesJSONLines())
        }
        if arguments.contains("system") && arguments.contains("df") {
            return processResult(invocation, stdout: dockerSystemDiskUsageJSON())
        }
        if arguments.contains("stats") {
            return processResult(invocation, stdout: dockerStatsJSONLines())
        }
        if arguments.contains("top") {
            return processResult(invocation, stdout: dockerTopOutput())
        }
        if arguments.contains("vm") && arguments.contains("start") {
            return processResult(invocation, stdout: daemonVMStartJSON())
        }
        return processResult(invocation, stdout: "ok\n")
    }

    private func processResult(
        _ invocation: CommandInvocation,
        exitCode: Int32 = 0,
        stdout: String = "",
        stderr: String = ""
    ) -> ProcessResult {
        ProcessResult(
            executable: invocation.executable,
            arguments: invocation.arguments,
            exitCode: exitCode,
            stdout: stdout,
            stderr: stderr
        )
    }

    private func dockerContainersJSONLines() -> String {
        (0..<options.containerCount).map { index in
            let running = index < options.runningContainerCount
            return jsonLine([
                "ID": "container-\(index)",
                "Names": "app-\(index)",
                "Image": "fixture/app:\(index % 4)",
                "Command": "\"sleep 3600\"",
                "CreatedAt": "2026-06-14 00:00:00 +0000 UTC",
                "RunningFor": running ? "2 minutes" : "",
                "Ports": running ? "127.0.0.1:\(8_000 + index)->80/tcp" : "",
                "State": running ? "running" : "exited",
                "Status": running ? "Up 2 minutes" : "Exited (0)",
                "Size": "0B",
                "Labels": index.isMultiple(of: 2)
                    ? "com.docker.compose.project=fixture,com.docker.compose.service=svc\(index)"
                    : ""
            ])
        }.joined(separator: "\n")
    }

    private func dockerImagesJSONLines() -> String {
        (0..<options.imageCount).map { index in
            jsonLine([
                "ID": "sha256:image-\(index)",
                "Repository": "fixture/image",
                "Tag": "\(index)",
                "Size": "\(64 + index)MB",
                "CreatedAt": "2026-06-14 00:00:00 +0000 UTC",
                "CreatedSince": "\(index + 1) days ago"
            ])
        }.joined(separator: "\n")
    }

    private func dockerVolumesJSONLines() -> String {
        (0..<options.volumeCount).map { index in
            jsonLine([
                "Name": "volume-\(index)",
                "Driver": "local",
                "Scope": "local",
                "Mountpoint": "/var/lib/docker/volumes/volume-\(index)/_data",
                "Labels": index.isMultiple(of: 2) ? "project=fixture" : ""
            ])
        }.joined(separator: "\n")
    }

    private func dockerSystemDiskUsageJSON() -> String {
        let volumes = (0..<options.volumeCount).map { index in
            [
                "Name": "volume-\(index)",
                "Size": "\(index + 1).0MB"
            ]
        }
        return jsonObject(["Volumes": volumes])
    }

    private func dockerStatsJSONLines() -> String {
        (0..<options.runningContainerCount).map { index in
            jsonLine([
                "Container": "container-\(index)",
                "Name": "app-\(index)",
                "CPUPerc": "\(index % 7).0%",
                "MemUsage": "\(16 + index)MiB / 2GiB",
                "MemPerc": "1.0%",
                "NetIO": "1kB / 1kB",
                "BlockIO": "0B / 0B",
                "PIDs": "2"
            ])
        }.joined(separator: "\n")
    }

    private func dockerTopOutput() -> String {
        """
        PID PPID USER STAT COMMAND
        1 0 root S sleep sleep 3600
        2 1 root S sh sh -c fixture
        """
    }

    private func daemonVMStartJSON() -> String {
        """
        {
          "ok": true,
          "message": "VM start accepted",
          "vm": {
            "state": "starting",
            "configured": true,
            "manifestPath": "\(paths.vmManifest.path)",
            "dockerSocketPath": "\(paths.dockerSocket.path)",
            "message": "starting",
            "events": []
          }
        }
        """
    }

    private func jsonLine(_ object: [String: String]) -> String {
        jsonObject(object)
    }

    private func jsonObject(_ object: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

private final class AppUIBenchmarkAsyncBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func awaitValue<Value>(_ operation: @escaping @Sendable () async -> Value) -> Value {
    let semaphore = DispatchSemaphore(value: 0)
    let box = AppUIBenchmarkAsyncBox<Value>()
    Task {
        let value = await operation()
        box.set(value)
        semaphore.signal()
    }
    semaphore.wait()
    return box.get()!
}

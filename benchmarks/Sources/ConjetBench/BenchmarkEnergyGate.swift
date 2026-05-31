import ConjetCore
import Foundation
#if os(macOS)
import Darwin
#endif

public struct BenchmarkEnergyGateOptions: Codable, Equatable, Sendable {
    public var contexts: [String]
    public var workloads: [String]
    public var samples: Int
    public var requirePower: Bool
    public var useSudo: Bool
    public var seconds: Double
    public var minimumActiveSeconds: Double
    public var workloadTimeoutSeconds: Double
    public var interval: Double
    public var samplers: String
    public var prepullImages: Bool

    public init(
        contexts: [String] = ["conjet", "orbstack"],
        workloads: [String] = ["idle", "container-start-loop", "hot-reload-loop", "compose-loop", "npm-install", "pnpm-install", "cargo-build"],
        samples: Int = 10,
        requirePower: Bool = false,
        useSudo: Bool = true,
        seconds: Double = 30,
        minimumActiveSeconds: Double = 10,
        workloadTimeoutSeconds: Double = 180,
        interval: Double = 1,
        samplers: String = "cpu_power,gpu_power,ane_power,tasks",
        prepullImages: Bool = true
    ) {
        self.contexts = contexts.filter { !$0.isEmpty }
        self.workloads = workloads.isEmpty ? ["idle"] : workloads
        self.samples = max(1, samples)
        self.requirePower = requirePower
        self.useSudo = useSudo
        self.seconds = max(1, seconds)
        self.minimumActiveSeconds = max(1, minimumActiveSeconds)
        self.workloadTimeoutSeconds = max(self.minimumActiveSeconds + 1, workloadTimeoutSeconds)
        self.interval = max(0.1, interval)
        self.samplers = samplers
        self.prepullImages = prepullImages
    }
}

public struct BenchmarkEnergyGateRunResult: Codable, Equatable, Sendable {
    public var options: BenchmarkEnergyGateOptions
    public var powermetricsAvailable: Bool
    public var skippedReason: String?
    public var outputDirectory: String
    public var allResultsReport: String
    public var markdownReport: String
    public var results: [BenchmarkResult]
}

public struct BenchmarkEnergyGateRunner {
    public var options: BenchmarkEnergyGateOptions
    private let runner: @Sendable (String, [String]) throws -> ProcessResult
    private let sudoAuthenticator: @Sendable () throws -> ProcessResult
    private let usesDefaultSudoAuthenticator: Bool

    public init(
        options: BenchmarkEnergyGateOptions = BenchmarkEnergyGateOptions(),
        sudoAuthenticator: (@Sendable () throws -> ProcessResult)? = nil,
        runner: (@Sendable (String, [String]) throws -> ProcessResult)? = nil
    ) {
        self.options = options
        if let sudoAuthenticator {
            self.sudoAuthenticator = sudoAuthenticator
            self.usesDefaultSudoAuthenticator = false
        } else {
            self.sudoAuthenticator = {
                try Self.runInteractiveSudoValidation()
            }
            self.usesDefaultSudoAuthenticator = true
        }
        self.runner = runner ?? { executable, arguments in
            try ProcessRunner.run(executable, arguments, timeoutSeconds: 300)
        }
    }

    public func run(outputDirectory: URL) throws -> BenchmarkEnergyGateRunResult {
        let outputDirectory = outputDirectory.standardizedFileURL
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let skippedReason = powerAvailabilitySkippedReason()
        let results: [BenchmarkResult]
        if let reason = skippedReason {
            if options.requirePower {
                throw ConjetError.unavailable(reason)
            }
            results = skippedResults(reason: reason)
        } else {
            results = collectMeasuredResults()
        }

        let allResultsReport = outputDirectory.appendingPathComponent("all-results.json")
        try ConjetJSON.encoder().encode(results).write(to: allResultsReport, options: .atomic)
        let markdownReport = outputDirectory.appendingPathComponent("energy-gate.md")
        try renderMarkdown(results: results, skippedReason: skippedReason)
            .write(to: markdownReport, atomically: true, encoding: .utf8)

        return BenchmarkEnergyGateRunResult(
            options: options,
            powermetricsAvailable: skippedReason == nil,
            skippedReason: skippedReason,
            outputDirectory: outputDirectory.path,
            allResultsReport: allResultsReport.path,
            markdownReport: markdownReport.path,
            results: results
        )
    }

    private func powerAvailabilitySkippedReason() -> String? {
        #if os(macOS)
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/powermetrics") else {
            return "powermetrics is not executable at /usr/bin/powermetrics"
        }
        if options.useSudo {
            let sudo = try? runner("/usr/bin/sudo", ["-n", "/usr/bin/true"])
            if sudo?.succeeded != true {
                guard options.requirePower else {
                    return "powermetrics requires sudo/noninteractive privileges"
                }
                if usesDefaultSudoAuthenticator && !Self.hasInteractiveTerminal() {
                    return "powermetrics requires sudo privileges; rerun from an interactive terminal or pre-authenticate with sudo -v"
                }
                let authenticated: ProcessResult
                do {
                    authenticated = try sudoAuthenticator()
                } catch {
                    return "sudo authentication failed before powermetrics: \(error)"
                }
                guard authenticated.succeeded else {
                    return authenticated.stderr.isEmpty
                        ? "sudo authentication failed before powermetrics"
                        : "sudo authentication failed before powermetrics: \(authenticated.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
                }
                let recheck = try? runner("/usr/bin/sudo", ["-n", "/usr/bin/true"])
                if recheck?.succeeded != true {
                    return "sudo authentication did not enable noninteractive powermetrics privileges"
                }
            }
        }
        return nil
        #else
        return "powermetrics is only available on macOS"
        #endif
    }

    private static func hasInteractiveTerminal() -> Bool {
        #if os(macOS)
        isatty(STDIN_FILENO) == 1 || FileManager.default.isReadableFile(atPath: "/dev/tty")
        #else
        false
        #endif
    }

    private static func runInteractiveSudoValidation(timeoutSeconds: Double = 120) throws -> ProcessResult {
        #if os(macOS)
        let executable = "/usr/bin/sudo"
        let arguments = ["-v"]
        let ttyInput = FileHandle(forReadingAtPath: "/dev/tty")
        let ttyOutput = FileHandle(forWritingAtPath: "/dev/tty")
        let ttyError = FileHandle(forWritingAtPath: "/dev/tty")
        let promptHandle = ttyError ?? FileHandle.standardError
        promptHandle.write(Data("energy gate: powermetrics requires sudo; authenticating with sudo -v\n".utf8))
        defer {
            try? ttyInput?.close()
            try? ttyOutput?.close()
            try? ttyError?.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = ttyInput ?? FileHandle.standardInput
        process.standardOutput = ttyOutput ?? FileHandle.standardOutput
        process.standardError = ttyError ?? FileHandle.standardError

        let waitSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            waitSemaphore.signal()
        }

        try process.run()
        let timeout = max(1, timeoutSeconds)
        var timedOut = false
        if waitSemaphore.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if waitSemaphore.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = waitSemaphore.wait(timeout: .now() + 2)
            }
        }

        return ProcessResult(
            executable: executable,
            arguments: arguments,
            exitCode: timedOut ? 124 : process.terminationStatus,
            stdout: "",
            stderr: timedOut ? "sudo password prompt timed out after \(Int(timeout))s" : ""
        )
        #else
        return ProcessResult(
            executable: "/usr/bin/sudo",
            arguments: ["-v"],
            exitCode: 1,
            stdout: "",
            stderr: "interactive sudo authentication is only supported on macOS"
        )
        #endif
    }

    private func skippedResults(reason: String) -> [BenchmarkResult] {
        let machine = MachineProfiler.capture()
        return options.contexts.flatMap { runtime in
            options.workloads.map { workload in
                var metrics = BenchmarkMetrics()
                metrics.setString("skipped", for: "energy_verdict")
                metrics.setString(reason, for: "energy_skip_reason")
                metrics.setNull(for: "average_power_watts")
                metrics.setNull(for: "package_power_watts")
                metrics.setNull(for: "cpu_power_watts")
                metrics.setNull(for: "wakeups_per_second")
                metrics.setNull(for: "energy_to_solution_joules")
                metrics.setString(machine.thermalState, for: "thermal_state_before")
                metrics.setString(machine.thermalState, for: "thermal_state_after")
                metrics.setString(machine.powerSource, for: "power_source")
                metrics.setBool(machine.host.lowPowerModeEnabled, for: "low_power_mode")
                return BenchmarkResult(
                    workload: workload,
                    runtime: runtime,
                    command: [],
                    startedAt: Date(),
                    durationSeconds: 0,
                    exitCode: 0,
                    metrics: metrics,
                    machine: machine,
                    stderrTail: reason
                )
            }
        }
    }

    private func collectMeasuredResults() -> [BenchmarkResult] {
        var results: [BenchmarkResult] = []
        let setupFailures = prepareActiveWorkloads()
        if !setupFailures.isEmpty {
            return setupFailures
        }
        for sample in 1...options.samples {
            for runtime in options.contexts {
                for workload in options.workloads {
                    FileHandle.standardError.write(Data("energy gate: sample \(sample)/\(options.samples) runtime=\(runtime) workload=\(workload)\n".utf8))
                    do {
                        var result = try collectMeasuredResult(runtime: runtime, workload: workload)
                        result.metrics["iteration"] = Double(sample)
                        result.metrics.setString("measured", for: "energy_verdict")
                        result.metrics.setString(result.machine.powerSource, for: "power_source")
                        result.metrics.setString(result.machine.thermalState, for: "thermal_state_before")
                        result.metrics.setString(MachineProfiler.capture().thermalState, for: "thermal_state_after")
                        result.metrics.setBool(result.machine.host.lowPowerModeEnabled, for: "low_power_mode")
                        results.append(result)
                    } catch {
                        results.append(failedResult(runtime: runtime, workload: workload, sample: sample, error: error))
                    }
                }
            }
        }
        return results
    }

    private func collectMeasuredResult(runtime: String, workload: String) throws -> BenchmarkResult {
        if workload == "idle" {
            return try PowerMetricsSampler(
                runtime: runtime,
                processPattern: BenchmarkReleaseGateRunner.defaultProcessPattern(runtime: runtime),
                durationSeconds: options.seconds,
                intervalSeconds: options.interval,
                samplers: options.samplers,
                useSudo: options.useSudo
            ).run()
        }

        return try ActivePowerSampler(
            runtime: runtime,
            workloadName: workload,
            processPattern: BenchmarkReleaseGateRunner.defaultProcessPattern(runtime: runtime),
            maxDurationSeconds: options.seconds,
            minSampleSeconds: min(options.minimumActiveSeconds, options.workloadTimeoutSeconds),
            workloadTimeoutSeconds: options.workloadTimeoutSeconds,
            intervalSeconds: options.interval,
            samplers: options.samplers,
            useSudo: options.useSudo
        ).run(
            executable: "/usr/bin/env",
            arguments: activeWorkloadCommand(runtime: runtime, workload: workload)
        )
    }

    private func activeWorkloadCommand(runtime: String, workload: String) -> [String] {
        let minimumActiveSeconds = max(1, Int(options.minimumActiveSeconds.rounded(.up)))
        let script: String
        switch workload {
        case "npm-install":
            script = repeatedActiveScript(
                minimumActiveSeconds: minimumActiveSeconds,
                command: "docker --context \"$1\" run --rm node:22-alpine sh -lc 'mkdir -p /app && cd /app && npm init -y >/dev/null && npm install is-number@7.0.0 --no-audit --no-fund --progress=false >/dev/null'"
            )
        case "pnpm-install":
            script = repeatedActiveScript(
                minimumActiveSeconds: minimumActiveSeconds,
                command: "docker --context \"$1\" run --rm node:22-alpine sh -lc '(corepack enable >/dev/null 2>&1 && corepack prepare pnpm@9.15.9 --activate >/dev/null 2>&1) || npm install -g pnpm@9.15.9 >/dev/null; mkdir -p /app && cd /app && npm init -y >/dev/null && pnpm add is-number@7.0.0 --reporter=silent >/dev/null'"
            )
        case "cargo-build":
            script = repeatedActiveScript(
                minimumActiveSeconds: minimumActiveSeconds,
                command: "docker --context \"$1\" run --rm rust:1-bookworm sh -c 'export PATH=\"/usr/local/cargo/bin:$PATH\"; cargo --version >/dev/null && cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null'"
            )
        default:
            script = repeatedActiveScript(
                minimumActiveSeconds: minimumActiveSeconds,
                command: "docker --context \"$1\" run --rm alpine:3.20 true >/dev/null"
            )
        }
        return ["sh", "-c", script, "conjet-energy-gate", runtime]
    }

    private func repeatedActiveScript(minimumActiveSeconds: Int, command: String) -> String {
        """
        set -eu
        start=$(date +%s)
        iterations=0
        while :; do
          \(command)
          iterations=$((iterations + 1))
          now=$(date +%s)
          if [ "$iterations" -ge 1 ] && [ $((now - start)) -ge \(minimumActiveSeconds) ]; then
            break
          fi
        done
        echo "iterations=$iterations"
        """
    }

    private func prepareActiveWorkloads() -> [BenchmarkResult] {
        guard options.prepullImages else { return [] }
        let images = requiredImages(for: options.workloads)
        guard !images.isEmpty else { return [] }

        var failures: [BenchmarkResult] = []
        for runtime in options.contexts {
            for image in images.sorted() {
                FileHandle.standardError.write(Data("energy gate: pre-pull runtime=\(runtime) image=\(image)\n".utf8))
                do {
                    let result = try runner("/usr/bin/env", ["docker", "--context", runtime, "pull", image])
                    guard result.succeeded else {
                        failures.append(setupFailureResult(
                            runtime: runtime,
                            image: image,
                            result: result
                        ))
                        continue
                    }
                } catch {
                    failures.append(failedResult(runtime: runtime, workload: "energy-setup-prepull", sample: 0, error: error))
                }
            }
        }
        return failures
    }

    private func requiredImages(for workloads: [String]) -> Set<String> {
        var images = Set<String>()
        for workload in workloads where workload != "idle" {
            switch workload {
            case "npm-install", "pnpm-install":
                images.insert("node:22-alpine")
            case "cargo-build":
                images.insert("rust:1-bookworm")
            default:
                images.insert("alpine:3.20")
            }
        }
        return images
    }

    private func setupFailureResult(runtime: String, image: String, result: ProcessResult) -> BenchmarkResult {
        var metrics = BenchmarkMetrics()
        metrics["iteration"] = 0
        metrics.setString("failed", for: "energy_verdict")
        metrics.setString("prepull_failed", for: "failure_reason")
        metrics.setString(image, for: "prepull_image")
        return BenchmarkResult(
            workload: "energy-setup-prepull",
            runtime: runtime,
            command: [result.executable] + result.arguments,
            startedAt: Date(),
            durationSeconds: 0,
            exitCode: result.exitCode,
            metrics: metrics,
            machine: MachineProfiler.capture(),
            stdoutTail: result.stdout,
            stderrTail: result.stderr
        )
    }

    private func failedResult(runtime: String, workload: String, sample: Int, error: Error) -> BenchmarkResult {
        var metrics = BenchmarkMetrics()
        metrics["iteration"] = Double(sample)
        metrics.setString("failed", for: "energy_verdict")
        return BenchmarkResult(
            workload: workload,
            runtime: runtime,
            command: [],
            startedAt: Date(),
            durationSeconds: 0,
            exitCode: 1,
            metrics: metrics,
            machine: MachineProfiler.capture(),
            stderrTail: String(describing: error)
        )
    }

    private func renderMarkdown(results: [BenchmarkResult], skippedReason: String?) -> String {
        var lines = [
            "# Conjet Energy Gate",
            "",
            "- Verdict: \(skippedReason == nil ? "measured" : "skipped")",
            "- Samples: \(options.samples)",
            "- Contexts: \(options.contexts.joined(separator: ", "))",
            "- Workloads: \(options.workloads.joined(separator: ", "))",
            ""
        ]
        if let skippedReason {
            lines.append("Energy claim status: Not proven.")
            lines.append("")
            lines.append("Reason: \(skippedReason)")
            lines.append("")
        }
        lines.append(BenchmarkMarkdownReport.render(results: results, title: "Conjet Energy Results"))
        return lines.joined(separator: "\n")
    }
}

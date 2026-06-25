import ConjetCore
import Foundation
#if os(macOS)
import Darwin
#endif

public struct ActivePowerSampler {
    public var runtime: String
    public var workloadName: String
    public var processPattern: String
    public var maxDurationSeconds: Double
    public var minSampleSeconds: Double
    public var workloadTimeoutSeconds: Double
    public var intervalSeconds: Double
    public var samplers: String
    public var useSudo: Bool

    public init(
        runtime: String,
        workloadName: String = "active-energy-sample",
        processPattern: String,
        maxDurationSeconds: Double = 60,
        minSampleSeconds: Double = 2,
        workloadTimeoutSeconds: Double? = nil,
        intervalSeconds: Double = 1,
        samplers: String = "cpu_power,gpu_power,ane_power,tasks",
        useSudo: Bool = true
    ) {
        self.runtime = runtime
        self.workloadName = workloadName
        self.processPattern = processPattern
        self.maxDurationSeconds = max(1, maxDurationSeconds)
        self.minSampleSeconds = max(0.1, minSampleSeconds)
        self.workloadTimeoutSeconds = max(1, workloadTimeoutSeconds ?? maxDurationSeconds)
        self.intervalSeconds = max(0.1, intervalSeconds)
        self.samplers = samplers
        self.useSudo = useSudo
    }

    public func run(
        executable: String,
        arguments: [String]
    ) throws -> BenchmarkResult {
        let machine = MachineProfiler.capture()
        let startedAt = Date()
        let sampleRateMilliseconds = max(100, Int((intervalSeconds * 1_000).rounded()))
        let sampleLimitSeconds = max(maxDurationSeconds, workloadTimeoutSeconds)
        let sampleCount = max(1, Int((sampleLimitSeconds / intervalSeconds).rounded(.up)))
        let powermetricsArguments = [
            "--samplers", samplers,
            "--show-process-energy",
            "--handle-invalid-values",
            "--buffer-size", "1",
            "--sample-rate", "\(sampleRateMilliseconds)",
            "--sample-count", "\(sampleCount)"
        ]
        let powerExecutable = useSudo ? "/usr/bin/sudo" : "/usr/bin/powermetrics"
        let powerArguments = useSudo
            ? ["-n", "/usr/bin/powermetrics"] + powermetricsArguments
            : powermetricsArguments

        let powerProcess = RunningProcess()
        try powerProcess.start(executable: powerExecutable, arguments: powerArguments)
        Thread.sleep(forTimeInterval: min(0.25, intervalSeconds))

        let workloadStartedAt = Date()
        let workload = try runWorkload(
            executable: executable,
            arguments: arguments,
            timeoutSeconds: workloadTimeoutSeconds
        )
        let workloadDuration = Date().timeIntervalSince(workloadStartedAt)

        let remainingMinimum = minSampleSeconds - Date().timeIntervalSince(startedAt)
        if remainingMinimum > 0 {
            Thread.sleep(forTimeInterval: remainingMinimum)
        }

        let power = powerProcess.stop()
        let powerDuration = Date().timeIntervalSince(startedAt)
        let powerOutput = power.stdout + "\n" + power.stderr
        var metrics = try PowerMetricsSampler.parseMetrics(powerOutput, processPattern: processPattern)
        metrics = Self.energyMetrics(
            powerMetrics: metrics,
            workloadDurationSeconds: workloadDuration,
            powerDurationSeconds: powerDuration
        )
        metrics["workload_exit_code"] = Double(workload.exitCode)
        metrics["power_exit_code"] = Double(power.exitCode)
        metrics["requested_sample_count"] = Double(sampleCount)
        metrics["requested_sample_rate_ms"] = Double(sampleRateMilliseconds)
        metrics["power_sample_limit_seconds"] = sampleLimitSeconds
        metrics["minimum_active_sample_seconds"] = minSampleSeconds
        metrics["workload_timeout_seconds"] = workloadTimeoutSeconds

        let exitCode: Int32 = workload.exitCode == 0 ? power.exitCode : workload.exitCode
        let command = [powerExecutable] + powerArguments + ["--workload", executable] + arguments
        return BenchmarkResult(
            workload: workloadName,
            runtime: runtime,
            command: command,
            startedAt: startedAt,
            durationSeconds: Date().timeIntervalSince(startedAt),
            exitCode: exitCode,
            metrics: metrics,
            machine: machine,
            stdoutTail: tail(
                "process_pattern=\(processPattern)\n" +
                    "workload_stdout:\n\(workload.stdout)\n" +
                    "powermetrics_stdout:\n\(power.stdout)"
            ),
            stderrTail: tail(
                "workload_stderr:\n\(workload.stderr)\n" +
                    "powermetrics_stderr:\n\(power.stderr)"
            )
        )
    }

    public static func energyMetrics(
        powerMetrics: [String: Double],
        workloadDurationSeconds: Double,
        powerDurationSeconds: Double
    ) -> [String: Double] {
        var metrics = powerMetrics
        let workloadDuration = max(0, workloadDurationSeconds)
        let powerDuration = max(0, powerDurationSeconds)
        metrics["workload_duration_seconds"] = workloadDuration
        metrics["power_sample_duration_seconds"] = powerDuration
        if let combinedPower = powerMetrics["combined_power_mw_mean"] {
            metrics["energy_to_solution_joules_estimate"] = combinedPower * workloadDuration / 1_000
            metrics["average_power_watts"] = combinedPower / 1_000
            metrics["energy_to_solution_joules"] = combinedPower * workloadDuration / 1_000
        }
        if let cpuPower = powerMetrics["cpu_power_mw_mean"] {
            metrics["cpu_energy_to_solution_joules_estimate"] = cpuPower * workloadDuration / 1_000
            metrics["cpu_power_watts"] = cpuPower / 1_000
        }
        if let wakeups = powerMetrics["matched_wakeups_per_second_mean"] {
            metrics["wakeups_per_second"] = wakeups
        }
        return metrics
    }

    private func runWorkload(
        executable: String,
        arguments: [String],
        timeoutSeconds: Double
    ) throws -> ProcessResult {
        try ProcessRunner.run(executable, arguments, timeoutSeconds: timeoutSeconds)
    }

    private func tail(_ text: String, limit: Int = 4096) -> String {
        if text.count <= limit { return text }
        return String(text.suffix(limit))
    }
}

private final class RunningProcess {
    private var process: Process?
    private let stdoutData = ActivePowerProcessData()
    private let stderrData = ActivePowerProcessData()
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private let terminationSemaphore = DispatchSemaphore(value: 0)

    func start(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [stdoutData] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stdoutData.append(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [stderrData] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrData.append(data)
            }
        }
        process.terminationHandler = { [terminationSemaphore] _ in
            terminationSemaphore.signal()
        }

        self.process = process
        try process.run()
    }

    func stop() -> ProcessResult {
        guard let process else {
            return ProcessResult(executable: "", arguments: [], exitCode: 1, stdout: "", stderr: "process was not started")
        }

        if process.isRunning {
            process.terminate()
            if terminationSemaphore.wait(timeout: .now() + 2) == .timedOut {
                #if os(macOS)
                kill(process.processIdentifier, SIGKILL)
                #endif
                _ = terminationSemaphore.wait(timeout: .now() + 2)
            }
        } else {
            _ = terminationSemaphore.wait(timeout: .now())
        }

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        if let remaining = stdoutPipe?.fileHandleForReading.readDataToEndOfFile(), !remaining.isEmpty {
            stdoutData.append(remaining)
        }
        if let remaining = stderrPipe?.fileHandleForReading.readDataToEndOfFile(), !remaining.isEmpty {
            stderrData.append(remaining)
        }

        return ProcessResult(
            executable: process.executableURL?.path ?? "",
            arguments: process.arguments ?? [],
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData.data(), encoding: .utf8) ?? "",
            stderr: String(data: stderrData.data(), encoding: .utf8) ?? ""
        )
    }
}

private final class ActivePowerProcessData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    func data() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

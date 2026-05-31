import ConjetCore
import Foundation

public struct PowerMetricsSampler {
    public var runtime: String
    public var processPattern: String
    public var durationSeconds: Double
    public var intervalSeconds: Double
    public var samplers: String
    public var useSudo: Bool

    private let runner: (String, [String]) throws -> ProcessResult

    public init(
        runtime: String,
        processPattern: String,
        durationSeconds: Double = 60,
        intervalSeconds: Double = 1,
        samplers: String = "cpu_power,gpu_power,ane_power,tasks",
        useSudo: Bool = true,
        runner: @escaping (String, [String]) throws -> ProcessResult = ProcessRunner.run
    ) {
        self.runtime = runtime
        self.processPattern = processPattern
        self.durationSeconds = max(1, durationSeconds)
        self.intervalSeconds = max(0.1, intervalSeconds)
        self.samplers = samplers
        self.useSudo = useSudo
        self.runner = runner
    }

    public func run() throws -> BenchmarkResult {
        let machine = MachineProfiler.capture()
        let startedAt = Date()
        let sampleRateMilliseconds = max(100, Int((intervalSeconds * 1_000).rounded()))
        let sampleCount = max(1, Int((durationSeconds / intervalSeconds).rounded(.up)))
        let powermetricsArguments = [
            "--samplers", samplers,
            "--show-process-energy",
            "--handle-invalid-values",
            "--buffer-size", "1",
            "--sample-rate", "\(sampleRateMilliseconds)",
            "--sample-count", "\(sampleCount)"
        ]
        let executable = useSudo ? "/usr/bin/sudo" : "/usr/bin/powermetrics"
        let arguments = useSudo
            ? ["-n", "/usr/bin/powermetrics"] + powermetricsArguments
            : powermetricsArguments
        let result = try runner(executable, arguments)
        let duration = Date().timeIntervalSince(startedAt)
        let output = result.stdout + "\n" + result.stderr
        var metrics = try Self.parseMetrics(output, processPattern: processPattern)
        metrics["requested_sample_count"] = Double(sampleCount)
        metrics["requested_sample_rate_ms"] = Double(sampleRateMilliseconds)
        if let combinedPower = metrics["combined_power_mw_mean"] {
            metrics["average_power_watts"] = combinedPower / 1_000
            metrics["idle_power_watts"] = combinedPower / 1_000
        }
        if let cpuPower = metrics["cpu_power_mw_mean"] {
            metrics["cpu_power_watts"] = cpuPower / 1_000
        }
        if let wakeups = metrics["matched_wakeups_per_second_mean"] {
            metrics["wakeups_per_second"] = wakeups
            metrics["idle_wakeups_per_second"] = wakeups
        }

        return BenchmarkResult(
            workload: "idle-power-sample",
            runtime: runtime,
            command: [executable] + arguments,
            startedAt: startedAt,
            durationSeconds: duration,
            exitCode: result.exitCode,
            metrics: metrics,
            machine: machine,
            stdoutTail: tail("process_pattern=\(processPattern)\n" + result.stdout),
            stderrTail: tail(result.stderr)
        )
    }

    public static func parseMetrics(_ output: String, processPattern: String) throws -> [String: Double] {
        let regex = try NSRegularExpression(pattern: processPattern, options: [.caseInsensitive])
        var cpuPower: [Double] = []
        var gpuPower: [Double] = []
        var anePower: [Double] = []
        var combinedPower: [Double] = []
        var matchedEnergyImpact: [Double] = []
        var matchedWakeups: [Double] = []
        var matchedIdleWakeups: [Double] = []
        var matchedProcessLines = 0
        var sampleMarkers = 0

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let lowercased = line.lowercased()
            if lowercased.contains("sampled system activity") || lowercased.contains("sampled processor activity") {
                sampleMarkers += 1
            }

            if let value = Self.value(afterLinePrefix: "CPU Power", in: line) {
                cpuPower.append(value)
            }
            if let value = Self.value(afterLinePrefix: "GPU Power", in: line) {
                gpuPower.append(value)
            }
            if let value = Self.value(afterLinePrefix: "ANE Power", in: line) {
                anePower.append(value)
            }
            if let value = Self.value(afterLinePrefix: "Combined Power", in: line) {
                combinedPower.append(value)
            }

            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard regex.firstMatch(in: line, options: [], range: range) != nil else {
                continue
            }

            matchedProcessLines += 1
            if let value = Self.value(afterPhrase: "energy impact", in: line) {
                matchedEnergyImpact.append(value)
            }
            if let value = Self.value(afterPhrase: "wakeups/sec", in: line)
                ?? Self.value(afterPhrase: "wakeups/s", in: line)
                ?? Self.value(afterPhrase: "wakeups", in: line) {
                matchedWakeups.append(value)
            }
            if let value = Self.value(afterPhrase: "idle wakeups/sec", in: line)
                ?? Self.value(afterPhrase: "idle wakeups/s", in: line)
                ?? Self.value(afterPhrase: "package idle wakeups", in: line) {
                matchedIdleWakeups.append(value)
            }
        }

        var metrics: [String: Double] = [
            "powermetrics_sample_count": Double(max(sampleMarkers, cpuPower.count, combinedPower.count)),
            "matched_process_lines": Double(matchedProcessLines)
        ]
        Self.addSummary(prefix: "cpu_power_mw", values: cpuPower, to: &metrics)
        Self.addSummary(prefix: "gpu_power_mw", values: gpuPower, to: &metrics)
        Self.addSummary(prefix: "ane_power_mw", values: anePower, to: &metrics)
        Self.addSummary(prefix: "combined_power_mw", values: combinedPower, to: &metrics)
        Self.addSummary(prefix: "matched_energy_impact", values: matchedEnergyImpact, to: &metrics)
        Self.addSummary(prefix: "matched_wakeups_per_second", values: matchedWakeups, to: &metrics)
        Self.addSummary(prefix: "matched_idle_wakeups_per_second", values: matchedIdleWakeups, to: &metrics)
        return metrics
    }

    private static func addSummary(prefix: String, values: [Double], to metrics: inout [String: Double]) {
        guard !values.isEmpty else { return }
        metrics["\(prefix)_mean"] = mean(values)
        metrics["\(prefix)_p50"] = percentile(values, 0.50)
        metrics["\(prefix)_p75"] = percentile(values, 0.75)
        metrics["\(prefix)_p95"] = percentile(values, 0.95)
        metrics["\(prefix)_p99"] = percentile(values, 0.99)
        metrics["\(prefix)_max"] = values.max() ?? 0
        metrics["\(prefix)_stddev"] = standardDeviation(values)
    }

    private static func value(afterLinePrefix prefix: String, in line: String) -> Double? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil else {
            return nil
        }
        return firstNumber(in: trimmed)
    }

    private static func value(afterPhrase phrase: String, in line: String) -> Double? {
        guard let range = line.range(of: phrase, options: [.caseInsensitive]) else {
            return nil
        }
        return firstNumber(in: String(line[range.upperBound...]))
    }

    private static func firstNumber(in text: String) -> Double? {
        var number = ""
        var seenDigit = false
        for scalar in text.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar) {
                number.unicodeScalars.append(scalar)
                seenDigit = true
            } else if scalar == "." && seenDigit && !number.contains(".") {
                number.unicodeScalars.append(scalar)
            } else if seenDigit {
                break
            }
        }
        return number.isEmpty ? nil : Double(number)
    }

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func percentile(_ values: [Double], _ percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * percentile).rounded(.up))))
        return sorted[index]
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let average = mean(values)
        let variance = values.reduce(0) { partial, value in
            let delta = value - average
            return partial + delta * delta
        } / Double(values.count)
        return sqrt(variance)
    }

    private func tail(_ text: String, limit: Int = 4096) -> String {
        if text.count <= limit { return text }
        return String(text.suffix(limit))
    }
}

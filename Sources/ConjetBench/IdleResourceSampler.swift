import ConjetCore
import Foundation

public struct IdleResourceSampler {
    public var runtime: String
    public var processPattern: String
    public var durationSeconds: Double
    public var intervalSeconds: Double

    private let runner: (String, [String]) throws -> ProcessResult

    public init(
        runtime: String,
        processPattern: String,
        durationSeconds: Double = 30,
        intervalSeconds: Double = 1,
        runner: @escaping (String, [String]) throws -> ProcessResult = ProcessRunner.run
    ) {
        self.runtime = runtime
        self.processPattern = processPattern
        self.durationSeconds = max(1, durationSeconds)
        self.intervalSeconds = max(0.1, intervalSeconds)
        self.runner = runner
    }

    public func run() throws -> BenchmarkResult {
        let regex = try NSRegularExpression(pattern: processPattern, options: [.caseInsensitive])
        let machine = MachineProfiler.capture()
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(durationSeconds)
        var cpuTotals: [Double] = []
        var memoryTotals: [Double] = []
        var processCounts: [Double] = []

        repeat {
            let sample = try sample(regex: regex)
            cpuTotals.append(sample.cpuPercent)
            memoryTotals.append(sample.memoryPercent)
            processCounts.append(Double(sample.processCount))
            if Date() < deadline {
                Thread.sleep(forTimeInterval: min(intervalSeconds, max(0.0, deadline.timeIntervalSinceNow)))
            }
        } while Date() < deadline

        let elapsed = Date().timeIntervalSince(startedAt)
        let metrics: [String: Double] = [
            "sample_count": Double(cpuTotals.count),
            "process_count_mean": mean(processCounts),
            "process_count_p50": percentile(processCounts, 0.50),
            "process_count_p75": percentile(processCounts, 0.75),
            "process_count_p95": percentile(processCounts, 0.95),
            "process_count_p99": percentile(processCounts, 0.99),
            "process_count_stddev": standardDeviation(processCounts),
            "cpu_percent_mean": mean(cpuTotals),
            "cpu_percent_p50": percentile(cpuTotals, 0.50),
            "cpu_percent_p75": percentile(cpuTotals, 0.75),
            "cpu_percent_p95": percentile(cpuTotals, 0.95),
            "cpu_percent_p99": percentile(cpuTotals, 0.99),
            "cpu_percent_max": cpuTotals.max() ?? 0,
            "cpu_percent_stddev": standardDeviation(cpuTotals),
            "memory_percent_mean": mean(memoryTotals),
            "memory_percent_p50": percentile(memoryTotals, 0.50),
            "memory_percent_p75": percentile(memoryTotals, 0.75),
            "memory_percent_p95": percentile(memoryTotals, 0.95),
            "memory_percent_p99": percentile(memoryTotals, 0.99),
            "memory_percent_max": memoryTotals.max() ?? 0,
            "memory_percent_stddev": standardDeviation(memoryTotals)
        ]

        return BenchmarkResult(
            workload: "idle-resource-sample",
            runtime: runtime,
            command: ["/bin/ps", "-axo", "pid=,pcpu=,pmem=,command="],
            startedAt: startedAt,
            durationSeconds: elapsed,
            exitCode: 0,
            metrics: metrics,
            machine: machine,
            stdoutTail: "pattern=\(processPattern)\n"
        )
    }

    private func sample(regex: NSRegularExpression) throws -> ResourceSample {
        let result = try runner("/bin/ps", ["-axo", "pid=,pcpu=,pmem=,command="])
        guard result.succeeded else {
            throw ConjetError.processFailed(
                executable: result.executable,
                exitCode: result.exitCode,
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }

        var cpu = 0.0
        var memory = 0.0
        var count = 0
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let text = String(line)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard regex.firstMatch(in: text, options: [], range: range) != nil,
                  let parsed = parsePSLine(text) else {
                continue
            }
            cpu += parsed.cpu
            memory += parsed.memory
            count += 1
        }
        return ResourceSample(cpuPercent: cpu, memoryPercent: memory, processCount: count)
    }

    private func parsePSLine(_ line: String) -> (cpu: Double, memory: Double)? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 4,
              Double(parts[0]) != nil,
              let cpu = Double(parts[1]),
              let memory = Double(parts[2]) else {
            return nil
        }
        return (cpu, memory)
    }

    private func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func percentile(_ values: [Double], _ percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * percentile).rounded(.up))))
        return sorted[index]
    }

    private func standardDeviation(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let average = mean(values)
        let variance = values.reduce(0) { partial, value in
            let delta = value - average
            return partial + delta * delta
        } / Double(values.count)
        return sqrt(variance)
    }
}

private struct ResourceSample {
    var cpuPercent: Double
    var memoryPercent: Double
    var processCount: Int
}

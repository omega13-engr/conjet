import Foundation

public enum BenchmarkMarkdownReport {
    public static func render(results: [BenchmarkResult], title: String = "Conjet Benchmark Report") -> String {
        var lines: [String] = [
            "# \(title)",
            "",
            "Generated results: \(results.count)",
            ""
        ]

        if let first = results.first {
            lines.append("## Machine")
            lines.append("")
            lines.append("- macOS: \(first.machine.host.macOSVersion) (\(first.machine.host.buildVersion))")
            lines.append("- Architecture: \(first.machine.host.architecture)")
            lines.append("- CPU: \(first.machine.host.cpuBrand)")
            lines.append("- Memory: \(first.machine.host.memoryBytes / 1_048_576) MiB")
            lines.append("- Power source: \(first.machine.powerSource)")
            lines.append("- Thermal state: \(first.machine.thermalState)")
            lines.append("")
        }

        lines.append("## Summary")
        lines.append("")
        lines.append("| Workload | Runtime | Samples | Failures | P50 (s) | P75 (s) | P95 (s) | P99 (s) | Mean (s) | StdDev (s) |")
        lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
        for summary in summaries(results) {
            lines.append(
                "| \(escape(summary.workload)) | \(escape(summary.runtime)) | \(summary.samples) | \(summary.failures) | \(format(summary.p50)) | \(format(summary.p75)) | \(format(summary.p95)) | \(format(summary.p99)) | \(format(summary.mean)) | \(format(summary.standardDeviation)) |"
            )
        }
        lines.append("")

        lines.append("## Results")
        lines.append("")
        lines.append("| Trace ID | Workload | Runtime | Duration (s) | Exit | Key Metrics |")
        lines.append("| --- | --- | ---: | ---: | ---: | --- |")
        for result in results {
            lines.append(
                "| \(escape(result.traceID ?? "")) | \(escape(result.workload)) | \(escape(result.runtime)) | \(format(result.durationSeconds)) | \(result.exitCode) | \(escape(metricSummary(result.metrics))) |"
            )
        }
        lines.append("")

        let failures = results.filter { $0.exitCode != 0 }
        if !failures.isEmpty {
            lines.append("## Failures")
            lines.append("")
            for failure in failures {
                lines.append("### \(failure.workload) / \(failure.runtime)")
                lines.append("")
                lines.append("- Exit: \(failure.exitCode)")
                lines.append("- Command: `\(escapeInline(failure.command.joined(separator: " ")))`")
                let stderr = failure.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
                if !stderr.isEmpty {
                    lines.append("")
                    lines.append("```text")
                    lines.append(stderr)
                    lines.append("```")
                }
                let stdout = failure.stdoutTail.trimmingCharacters(in: .whitespacesAndNewlines)
                if !stdout.isEmpty {
                    lines.append("")
                    lines.append("```text")
                    lines.append(stdout)
                    lines.append("```")
                }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    private struct Summary {
        var workload: String
        var runtime: String
        var samples: Int
        var failures: Int
        var p50: Double
        var p75: Double
        var p95: Double
        var p99: Double
        var mean: Double
        var standardDeviation: Double
    }

    private static func summaries(_ results: [BenchmarkResult]) -> [Summary] {
        let grouped = Dictionary(grouping: results) { result in
            "\(result.workload)\u{0}\(result.runtime)"
        }
        return grouped.compactMap { _, values -> Summary? in
            guard let first = values.first else { return nil }
            let durations = values.map(\.durationSeconds).sorted()
            let mean = durations.reduce(0, +) / Double(durations.count)
            let variance = durations.reduce(0) { partial, value in
                let delta = value - mean
                return partial + delta * delta
            } / Double(durations.count)
            return Summary(
                workload: first.workload,
                runtime: first.runtime,
                samples: values.count,
                failures: values.filter { $0.exitCode != 0 }.count,
                p50: percentile(0.50, durations: durations),
                p75: percentile(0.75, durations: durations),
                p95: percentile(0.95, durations: durations),
                p99: percentile(0.99, durations: durations),
                mean: mean,
                standardDeviation: sqrt(variance)
            )
        }.sorted {
            if $0.workload == $1.workload {
                return $0.runtime < $1.runtime
            }
            return $0.workload < $1.workload
        }
    }

    private static func percentile(_ percentile: Double, durations: [Double]) -> Double {
        guard !durations.isEmpty else { return 0 }
        let rank = Int(ceil(percentile * Double(durations.count))) - 1
        return durations[max(0, min(rank, durations.count - 1))]
    }

    private static func metricSummary(_ metrics: [String: Double]) -> String {
        metrics
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(format($0.value))" }
            .joined(separator: ", ")
    }

    private static func format(_ value: Double) -> String {
        if value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(format: "%.3f", value)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
    }

    private static func escapeInline(_ text: String) -> String {
        text.replacingOccurrences(of: "`", with: "\\`")
    }
}

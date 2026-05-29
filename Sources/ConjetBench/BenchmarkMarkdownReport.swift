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

        lines.append("## Results")
        lines.append("")
        lines.append("| Workload | Runtime | Duration (s) | Exit | Key Metrics |")
        lines.append("| --- | ---: | ---: | ---: | --- |")
        for result in results {
            lines.append(
                "| \(escape(result.workload)) | \(escape(result.runtime)) | \(format(result.durationSeconds)) | \(result.exitCode) | \(escape(metricSummary(result.metrics))) |"
            )
        }
        lines.append("")
        return lines.joined(separator: "\n")
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
}

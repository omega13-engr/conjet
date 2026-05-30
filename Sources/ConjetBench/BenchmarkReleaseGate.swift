import ConjetCore
import Foundation

public struct BenchmarkReleaseGateOptions: Codable, Equatable, Sendable {
    public var contexts: [String]
    public var candidateRuntime: String
    public var baselineRuntimes: [String]
    public var iterations: Int
    public var minimumSamples: Int
    public var workloads: [String]
    public var warmup: Bool
    public var samplePhase: BenchmarkSamplePhase
    public var includeIdle: Bool
    public var includePower: Bool
    public var idleSeconds: Double
    public var idleInterval: Double
    public var powerSeconds: Double
    public var powerInterval: Double
    public var powerSamplers: String
    public var useSudoForPower: Bool

    public init(
        contexts: [String] = [],
        candidateRuntime: String = "conjet",
        baselineRuntimes: [String] = ["orbstack", "colima"],
        iterations: Int = 3,
        minimumSamples: Int = 3,
        workloads: [String] = DockerBenchmarkSuite.defaultWorkloads,
        warmup: Bool = false,
        samplePhase: BenchmarkSamplePhase? = nil,
        includeIdle: Bool = true,
        includePower: Bool = true,
        idleSeconds: Double = 30,
        idleInterval: Double = 1,
        powerSeconds: Double = 60,
        powerInterval: Double = 1,
        powerSamplers: String = "cpu_power,gpu_power,ane_power,tasks",
        useSudoForPower: Bool = true
    ) {
        self.candidateRuntime = candidateRuntime
        self.baselineRuntimes = Self.unique(baselineRuntimes.filter { !$0.isEmpty })
        self.contexts = Self.normalizedContexts(
            contexts,
            candidateRuntime: candidateRuntime,
            baselineRuntimes: self.baselineRuntimes
        )
        self.iterations = max(1, iterations)
        self.minimumSamples = max(1, minimumSamples)
        self.workloads = workloads.isEmpty ? DockerBenchmarkSuite.defaultWorkloads : Self.unique(workloads)
        self.warmup = warmup
        self.samplePhase = samplePhase ?? (warmup ? .warm : .cold)
        self.includeIdle = includeIdle
        self.includePower = includePower
        self.idleSeconds = max(1, idleSeconds)
        self.idleInterval = max(0.1, idleInterval)
        self.powerSeconds = max(1, powerSeconds)
        self.powerInterval = max(0.1, powerInterval)
        self.powerSamplers = powerSamplers
        self.useSudoForPower = useSudoForPower
    }

    public var effectiveGateRules: [BenchmarkClaimRule] {
        let selectedWorkloads = Set(workloads)
        return BenchmarkClaimGateOptions.defaultRules.filter { rule in
            switch rule.workload {
            case "idle-resource-sample":
                return includeIdle
            case "idle-power-sample":
                return includePower
            default:
                return selectedWorkloads.contains(rule.workload) ||
                    selectedWorkloads.contains(rule.resolvedCandidateWorkload) ||
                    selectedWorkloads.contains(rule.resolvedBaselineWorkload)
            }
        }
    }

    public var effectiveDockerWorkloads: [String] {
        let concreteWorkloads = Set(DockerBenchmarkSuite.defaultWorkloads)
        var selected = Self.unique(workloads.filter { concreteWorkloads.contains($0) })
        var seen = Set(selected)

        for rule in effectiveGateRules {
            for workload in [rule.resolvedCandidateWorkload, rule.resolvedBaselineWorkload]
                where concreteWorkloads.contains(workload) && !seen.contains(workload) {
                selected.append(workload)
                seen.insert(workload)
            }
        }

        return selected
    }

    private static func normalizedContexts(
        _ contexts: [String],
        candidateRuntime: String,
        baselineRuntimes: [String]
    ) -> [String] {
        let explicit = contexts.filter { !$0.isEmpty }
        if !explicit.isEmpty {
            return unique(explicit)
        }
        return unique(([candidateRuntime] + baselineRuntimes).filter { !$0.isEmpty })
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values where !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }
        return result
    }
}

public struct BenchmarkReleaseGateArtifacts: Codable, Equatable, Sendable {
    public var outputDirectory: String
    public var workDirectory: String
    public var dockerReport: String
    public var idleReports: [String]
    public var powerReports: [String]
    public var allResultsReport: String
    public var allResultsMarkdown: String
    public var gateReport: String
    public var gateMarkdownReport: String

    public init(
        outputDirectory: String,
        workDirectory: String,
        dockerReport: String,
        idleReports: [String],
        powerReports: [String],
        allResultsReport: String,
        allResultsMarkdown: String,
        gateReport: String,
        gateMarkdownReport: String
    ) {
        self.outputDirectory = outputDirectory
        self.workDirectory = workDirectory
        self.dockerReport = dockerReport
        self.idleReports = idleReports
        self.powerReports = powerReports
        self.allResultsReport = allResultsReport
        self.allResultsMarkdown = allResultsMarkdown
        self.gateReport = gateReport
        self.gateMarkdownReport = gateMarkdownReport
    }
}

public struct BenchmarkReleaseGateRunResult: Codable, Equatable, Sendable {
    public var options: BenchmarkReleaseGateOptions
    public var artifacts: BenchmarkReleaseGateArtifacts
    public var gateReport: BenchmarkClaimGateReport

    public init(
        options: BenchmarkReleaseGateOptions,
        artifacts: BenchmarkReleaseGateArtifacts,
        gateReport: BenchmarkClaimGateReport
    ) {
        self.options = options
        self.artifacts = artifacts
        self.gateReport = gateReport
    }
}

public struct BenchmarkReleaseGateRunner {
    public typealias DockerCollector = (
        _ contexts: [String],
        _ iterations: Int,
        _ warmup: Bool,
        _ workloads: [String],
        _ workDirectory: URL
    ) throws -> [BenchmarkResult]
    public typealias RuntimeCollector = (_ runtime: String, _ iteration: Int) throws -> BenchmarkResult

    public var options: BenchmarkReleaseGateOptions
    private let dockerCollector: DockerCollector
    private let idleCollector: RuntimeCollector
    private let powerCollector: RuntimeCollector

    public init(
        options: BenchmarkReleaseGateOptions = BenchmarkReleaseGateOptions(),
        dockerCollector: DockerCollector? = nil,
        idleCollector: RuntimeCollector? = nil,
        powerCollector: RuntimeCollector? = nil
    ) {
        self.options = options
        self.dockerCollector = dockerCollector ?? { contexts, iterations, warmup, workloads, workDirectory in
            try DockerBenchmarkSuite(
                contexts: contexts,
                iterations: iterations,
                warmup: warmup,
                workloads: workloads
            ).run(workDirectory: workDirectory)
        }
        self.idleCollector = idleCollector ?? { runtime, _ in
            try IdleResourceSampler(
                runtime: runtime,
                processPattern: Self.defaultProcessPattern(runtime: runtime),
                durationSeconds: options.idleSeconds,
                intervalSeconds: options.idleInterval
            ).run()
        }
        self.powerCollector = powerCollector ?? { runtime, _ in
            try PowerMetricsSampler(
                runtime: runtime,
                processPattern: Self.defaultProcessPattern(runtime: runtime),
                durationSeconds: options.powerSeconds,
                intervalSeconds: options.powerInterval,
                samplers: options.powerSamplers,
                useSudo: options.useSudoForPower
            ).run()
        }
    }

    public func run(outputDirectory: URL, workDirectory explicitWorkDirectory: URL? = nil) throws -> BenchmarkReleaseGateRunResult {
        let rules = options.effectiveGateRules
        guard !rules.isEmpty else {
            throw ConjetError.invalidArgument("release gate has no claim rules; select at least one gated workload or enable idle/power sampling")
        }

        let fileManager = FileManager.default
        let outputDirectory = outputDirectory.standardizedFileURL
        let workDirectory = (explicitWorkDirectory ?? outputDirectory.appendingPathComponent("work", isDirectory: true))
            .standardizedFileURL
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        var allResults: [BenchmarkResult] = []
        var idleReportPaths: [String] = []
        var powerReportPaths: [String] = []

        let dockerWorkDirectory = workDirectory.appendingPathComponent("docker", isDirectory: true)
        let dockerResults = try dockerCollector(
            options.contexts,
            options.iterations,
            options.warmup,
            options.effectiveDockerWorkloads,
            dockerWorkDirectory
        ).map(addSamplePhaseIfMissing)
        allResults.append(contentsOf: dockerResults)
        let dockerReport = outputDirectory.appendingPathComponent("docker.json")
        try writeJSON(dockerResults, to: dockerReport)

        if options.includeIdle {
            for runtime in options.contexts {
                let runtimeResults = try collectRuntimeSamples(collector: idleCollector, runtime: runtime)
                allResults.append(contentsOf: runtimeResults)
                let report = outputDirectory.appendingPathComponent("idle-\(runtime.sanitizedBenchmarkPathComponent).json")
                try writeJSON(runtimeResults, to: report)
                idleReportPaths.append(report.path)
            }
        }

        if options.includePower {
            for runtime in options.contexts {
                let runtimeResults = try collectRuntimeSamples(collector: powerCollector, runtime: runtime)
                allResults.append(contentsOf: runtimeResults)
                let report = outputDirectory.appendingPathComponent("power-\(runtime.sanitizedBenchmarkPathComponent).json")
                try writeJSON(runtimeResults, to: report)
                powerReportPaths.append(report.path)
            }
        }

        let allResultsReport = outputDirectory.appendingPathComponent("all-results.json")
        try writeJSON(allResults, to: allResultsReport)
        let allResultsMarkdown = outputDirectory.appendingPathComponent("all-results.md")
        try BenchmarkMarkdownReport
            .render(results: allResults, title: "Conjet Release Gate Benchmark")
            .write(to: allResultsMarkdown, atomically: true, encoding: .utf8)

        let gateReport = BenchmarkClaimGate.evaluate(
            results: allResults,
            options: BenchmarkClaimGateOptions(
                candidateRuntime: options.candidateRuntime,
                baselineRuntimes: options.baselineRuntimes,
                minimumSamples: options.minimumSamples,
                samplePhase: options.samplePhase,
                rules: rules
            )
        )
        let gateReportPath = outputDirectory.appendingPathComponent("gate.json")
        try writeJSON(gateReport, to: gateReportPath)
        let gateMarkdownReport = outputDirectory.appendingPathComponent("gate.md")
        try BenchmarkClaimGateMarkdownReport
            .render(gateReport)
            .write(to: gateMarkdownReport, atomically: true, encoding: .utf8)

        let artifacts = BenchmarkReleaseGateArtifacts(
            outputDirectory: outputDirectory.path,
            workDirectory: workDirectory.path,
            dockerReport: dockerReport.path,
            idleReports: idleReportPaths,
            powerReports: powerReportPaths,
            allResultsReport: allResultsReport.path,
            allResultsMarkdown: allResultsMarkdown.path,
            gateReport: gateReportPath.path,
            gateMarkdownReport: gateMarkdownReport.path
        )
        return BenchmarkReleaseGateRunResult(options: options, artifacts: artifacts, gateReport: gateReport)
    }

    public static func defaultProcessPattern(runtime: String) -> String {
        switch runtime.lowercased() {
        case "conjet":
            return "conjetd"
        case "colima":
            return "colima|lima|qemu|vz|socket_vmnet"
        case "orbstack":
            return "orbstack"
        case "docker", "docker-desktop":
            return "docker|com\\.docker"
        default:
            return runtime
        }
    }

    private func collectRuntimeSamples(collector: RuntimeCollector, runtime: String) throws -> [BenchmarkResult] {
        try (1...options.iterations).map { iteration in
            var result = try collector(runtime, iteration)
            result.metrics["iteration"] = Double(iteration)
            result = addSamplePhaseIfMissing(result)
            return result
        }
    }

    private func addSamplePhaseIfMissing(_ result: BenchmarkResult) -> BenchmarkResult {
        guard let phaseValue = options.samplePhase.metricValue else {
            return result
        }
        var result = result
        if result.metrics[BenchmarkSamplePhase.metricKey] == nil {
            result.metrics[BenchmarkSamplePhase.metricKey] = phaseValue
        }
        return result
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try ConjetJSON.encoder().encode(value)
        try data.write(to: url, options: .atomic)
    }
}

public enum BenchmarkClaimGateMarkdownReport {
    public static func render(_ report: BenchmarkClaimGateReport) -> String {
        var lines: [String] = [
            "# Conjet Benchmark Claim Gate",
            "",
            "- Verdict: \(report.passed ? "passed" : "failed")",
            "- Candidate: \(report.candidateRuntime)",
            "- Baselines: \(report.baselineRuntimes.joined(separator: ", "))",
            "- Minimum samples: \(report.minimumSamples)",
            "- Sample phase: \(report.samplePhase.rawValue)",
            ""
        ]

        if !report.missingRequirements.isEmpty {
            lines.append("## Missing Requirements")
            lines.append("")
            for requirement in report.missingRequirements {
                lines.append("- \(requirement)")
            }
            lines.append("")
        }

        lines.append("## Comparisons")
        lines.append("")
        lines.append("| Claim | Candidate Workload | Baseline | Baseline Workload | Measure | Candidate P50 | Baseline P50 | P50 Ratio | Candidate P95 | Baseline P95 | P95 Ratio | Result |")
        lines.append("| --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |")
        for comparison in report.comparisons {
            lines.append(
                "| \(comparison.workload) | \(comparison.candidateWorkload) | \(comparison.baselineRuntime) | \(comparison.baselineWorkload) | \(comparison.measure) | \(formatOptional(comparison.candidateP50)) | \(formatOptional(comparison.baselineP50)) | \(formatOptional(comparison.p50Ratio)) | \(formatOptional(comparison.candidateP95)) | \(formatOptional(comparison.baselineP95)) | \(formatOptional(comparison.p95Ratio)) | \(comparison.passed ? "pass" : comparison.reason) |"
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func formatOptional(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        if value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(format: "%.3f", value)
    }
}

private extension String {
    var sanitizedBenchmarkPathComponent: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = unicodeScalars.map { scalar -> String in
            allowed.contains(scalar) ? String(scalar) : "-"
        }
        let value = scalars.joined()
        return value.isEmpty ? "runtime" : value
    }
}

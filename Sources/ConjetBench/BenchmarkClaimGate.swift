import ConjetCore
import Foundation

public enum BenchmarkSamplePhase: String, Codable, Equatable, Sendable {
    case any
    case cold
    case warm

    public static let metricKey = "benchmark_phase"

    public var metricValue: Double? {
        switch self {
        case .any:
            return nil
        case .cold:
            return 0
        case .warm:
            return 1
        }
    }

    public func matches(_ result: BenchmarkResult) -> Bool {
        switch self {
        case .any:
            return true
        case .cold:
            return result.metrics[Self.metricKey] == Self.cold.metricValue
        case .warm:
            return result.metrics[Self.metricKey] == Self.warm.metricValue
        }
    }
}

public enum BenchmarkMeasure: Codable, Equatable, Sendable {
    case durationSeconds
    case metric(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case metric
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "durationSeconds":
            self = .durationSeconds
        case "metric":
            self = .metric(try container.decode(String.self, forKey: .metric))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown measure kind")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .durationSeconds:
            try container.encode("durationSeconds", forKey: .kind)
        case .metric(let name):
            try container.encode("metric", forKey: .kind)
            try container.encode(name, forKey: .metric)
        }
    }

    public var label: String {
        switch self {
        case .durationSeconds:
            return "durationSeconds"
        case .metric(let name):
            return name
        }
    }
}

public struct BenchmarkClaimRule: Codable, Equatable, Sendable {
    public var workload: String
    public var candidateWorkload: String?
    public var baselineWorkload: String?
    public var measure: BenchmarkMeasure
    public var maxP50Ratio: Double
    public var maxP95Ratio: Double

    public init(
        workload: String,
        candidateWorkload: String? = nil,
        baselineWorkload: String? = nil,
        measure: BenchmarkMeasure = .durationSeconds,
        maxP50Ratio: Double = 1.0,
        maxP95Ratio: Double = 1.0
    ) {
        self.workload = workload
        self.candidateWorkload = candidateWorkload
        self.baselineWorkload = baselineWorkload
        self.measure = measure
        self.maxP50Ratio = maxP50Ratio
        self.maxP95Ratio = maxP95Ratio
    }

    public var resolvedCandidateWorkload: String {
        candidateWorkload ?? workload
    }

    public var resolvedBaselineWorkload: String {
        baselineWorkload ?? workload
    }
}

public struct BenchmarkClaimGateOptions: Codable, Equatable, Sendable {
    public var candidateRuntime: String
    public var baselineRuntimes: [String]
    public var minimumSamples: Int
    public var samplePhase: BenchmarkSamplePhase
    public var rules: [BenchmarkClaimRule]

    public init(
        candidateRuntime: String = "conjet",
        baselineRuntimes: [String] = ["orbstack", "colima"],
        minimumSamples: Int = 3,
        samplePhase: BenchmarkSamplePhase = .any,
        rules: [BenchmarkClaimRule] = BenchmarkClaimGateOptions.defaultRules
    ) {
        self.candidateRuntime = candidateRuntime
        self.baselineRuntimes = baselineRuntimes
        self.minimumSamples = minimumSamples
        self.samplePhase = samplePhase
        self.rules = rules
    }

    public static let defaultRules: [BenchmarkClaimRule] = [
        BenchmarkClaimRule(workload: "container-start"),
        BenchmarkClaimRule(workload: "image-build"),
        BenchmarkClaimRule(workload: "copy-node-modules"),
        BenchmarkClaimRule(workload: "npm-install"),
        BenchmarkClaimRule(workload: "pnpm-install"),
        BenchmarkClaimRule(workload: "cargo-build"),
        BenchmarkClaimRule(workload: "bind-npm-install"),
        BenchmarkClaimRule(workload: "bind-pnpm-install"),
        BenchmarkClaimRule(workload: "bind-cargo-build"),
        BenchmarkClaimRule(workload: "volume-npm-install"),
        BenchmarkClaimRule(workload: "volume-pnpm-install"),
        BenchmarkClaimRule(workload: "volume-cargo-build"),
        BenchmarkClaimRule(workload: "named-volume-io"),
        BenchmarkClaimRule(workload: "tmpfs-volume-io"),
        BenchmarkClaimRule(
            workload: "npm-install-fast-path",
            candidateWorkload: "conjetfs-npm-install",
            baselineWorkload: "bind-npm-install"
        ),
        BenchmarkClaimRule(
            workload: "pnpm-install-fast-path",
            candidateWorkload: "conjetfs-pnpm-install",
            baselineWorkload: "bind-pnpm-install"
        ),
        BenchmarkClaimRule(
            workload: "cargo-build-fast-path",
            candidateWorkload: "conjetfs-cargo-build",
            baselineWorkload: "bind-cargo-build"
        ),
        BenchmarkClaimRule(
            workload: "hot-reload-fast-path",
            candidateWorkload: "conjetfs-hot-reload",
            baselineWorkload: "bind-hot-reload",
            measure: .metric("hot_reload_seconds")
        ),
        BenchmarkClaimRule(workload: "compose-up"),
        BenchmarkClaimRule(workload: "idle-resource-sample", measure: .metric("cpu_percent_mean")),
        BenchmarkClaimRule(workload: "idle-power-sample", measure: .metric("combined_power_mw_mean"))
    ]
}

public struct BenchmarkClaimGateReport: Codable, Equatable, Sendable {
    public var passed: Bool
    public var candidateRuntime: String
    public var baselineRuntimes: [String]
    public var minimumSamples: Int
    public var samplePhase: BenchmarkSamplePhase
    public var comparisons: [BenchmarkClaimComparison]
    public var missingRequirements: [String]

    public init(
        passed: Bool,
        candidateRuntime: String,
        baselineRuntimes: [String],
        minimumSamples: Int,
        samplePhase: BenchmarkSamplePhase,
        comparisons: [BenchmarkClaimComparison],
        missingRequirements: [String]
    ) {
        self.passed = passed
        self.candidateRuntime = candidateRuntime
        self.baselineRuntimes = baselineRuntimes
        self.minimumSamples = minimumSamples
        self.samplePhase = samplePhase
        self.comparisons = comparisons
        self.missingRequirements = missingRequirements
    }
}

public struct BenchmarkClaimComparison: Codable, Equatable, Sendable {
    public var workload: String
    public var candidateWorkload: String
    public var baselineWorkload: String
    public var measure: String
    public var baselineRuntime: String
    public var candidateSamples: Int
    public var baselineSamples: Int
    public var candidateFailures: Int
    public var baselineFailures: Int
    public var candidateP50: Double?
    public var baselineP50: Double?
    public var candidateP95: Double?
    public var baselineP95: Double?
    public var p50Ratio: Double?
    public var p95Ratio: Double?
    public var passed: Bool
    public var reason: String

    public init(
        workload: String,
        candidateWorkload: String? = nil,
        baselineWorkload: String? = nil,
        measure: String,
        baselineRuntime: String,
        candidateSamples: Int,
        baselineSamples: Int,
        candidateFailures: Int,
        baselineFailures: Int,
        candidateP50: Double?,
        baselineP50: Double?,
        candidateP95: Double?,
        baselineP95: Double?,
        p50Ratio: Double?,
        p95Ratio: Double?,
        passed: Bool,
        reason: String
    ) {
        self.workload = workload
        self.candidateWorkload = candidateWorkload ?? workload
        self.baselineWorkload = baselineWorkload ?? workload
        self.measure = measure
        self.baselineRuntime = baselineRuntime
        self.candidateSamples = candidateSamples
        self.baselineSamples = baselineSamples
        self.candidateFailures = candidateFailures
        self.baselineFailures = baselineFailures
        self.candidateP50 = candidateP50
        self.baselineP50 = baselineP50
        self.candidateP95 = candidateP95
        self.baselineP95 = baselineP95
        self.p50Ratio = p50Ratio
        self.p95Ratio = p95Ratio
        self.passed = passed
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case workload
        case candidateWorkload
        case baselineWorkload
        case measure
        case baselineRuntime
        case candidateSamples
        case baselineSamples
        case candidateFailures
        case baselineFailures
        case candidateP50
        case baselineP50
        case candidateP95
        case baselineP95
        case p50Ratio
        case p95Ratio
        case passed
        case reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let workload = try container.decode(String.self, forKey: .workload)
        self.workload = workload
        self.candidateWorkload = try container.decodeIfPresent(String.self, forKey: .candidateWorkload) ?? workload
        self.baselineWorkload = try container.decodeIfPresent(String.self, forKey: .baselineWorkload) ?? workload
        self.measure = try container.decode(String.self, forKey: .measure)
        self.baselineRuntime = try container.decode(String.self, forKey: .baselineRuntime)
        self.candidateSamples = try container.decode(Int.self, forKey: .candidateSamples)
        self.baselineSamples = try container.decode(Int.self, forKey: .baselineSamples)
        self.candidateFailures = try container.decode(Int.self, forKey: .candidateFailures)
        self.baselineFailures = try container.decode(Int.self, forKey: .baselineFailures)
        self.candidateP50 = try container.decodeIfPresent(Double.self, forKey: .candidateP50)
        self.baselineP50 = try container.decodeIfPresent(Double.self, forKey: .baselineP50)
        self.candidateP95 = try container.decodeIfPresent(Double.self, forKey: .candidateP95)
        self.baselineP95 = try container.decodeIfPresent(Double.self, forKey: .baselineP95)
        self.p50Ratio = try container.decodeIfPresent(Double.self, forKey: .p50Ratio)
        self.p95Ratio = try container.decodeIfPresent(Double.self, forKey: .p95Ratio)
        self.passed = try container.decode(Bool.self, forKey: .passed)
        self.reason = try container.decode(String.self, forKey: .reason)
    }
}

public enum BenchmarkClaimGate {
    public static func evaluate(
        results: [BenchmarkResult],
        options: BenchmarkClaimGateOptions = BenchmarkClaimGateOptions()
    ) -> BenchmarkClaimGateReport {
        var comparisons: [BenchmarkClaimComparison] = []
        var missing: [String] = []

        for rule in options.rules {
            let candidateWorkload = rule.resolvedCandidateWorkload
            let baselineWorkload = rule.resolvedBaselineWorkload
            let candidate = summarize(
                results: results,
                runtime: options.candidateRuntime,
                workload: candidateWorkload,
                measure: rule.measure,
                samplePhase: options.samplePhase
            )
            if candidate.samples < options.minimumSamples {
                missing.append("\(requirementLabel(rule: rule, workload: candidateWorkload, runtime: options.candidateRuntime, role: "candidate")): expected at least \(options.minimumSamples) samples, got \(candidate.samples)")
            }
            if candidate.missingMeasure {
                missing.append("\(requirementLabel(rule: rule, workload: candidateWorkload, runtime: options.candidateRuntime, role: "candidate")): missing measure \(rule.measure.label)")
            }

            for baselineRuntime in options.baselineRuntimes {
                let baseline = summarize(
                    results: results,
                    runtime: baselineRuntime,
                    workload: baselineWorkload,
                    measure: rule.measure,
                    samplePhase: options.samplePhase
                )
                let baselineIsFailedEvidence = baseline.samples >= options.minimumSamples &&
                    baseline.failures == baseline.samples &&
                    candidate.samples >= options.minimumSamples &&
                    candidate.failures == 0
                if baseline.samples < options.minimumSamples {
                    missing.append("\(requirementLabel(rule: rule, workload: baselineWorkload, runtime: baselineRuntime, role: "baseline")): expected at least \(options.minimumSamples) samples, got \(baseline.samples)")
                }
                if baseline.missingMeasure && !baselineIsFailedEvidence {
                    missing.append("\(requirementLabel(rule: rule, workload: baselineWorkload, runtime: baselineRuntime, role: "baseline")): missing measure \(rule.measure.label)")
                }

                let comparison = compare(
                    rule: rule,
                    baselineRuntime: baselineRuntime,
                    candidate: candidate,
                    baseline: baseline,
                    minimumSamples: options.minimumSamples
                )
                comparisons.append(comparison)
            }
        }

        let passed = missing.isEmpty && comparisons.allSatisfy(\.passed)
        return BenchmarkClaimGateReport(
            passed: passed,
            candidateRuntime: options.candidateRuntime,
            baselineRuntimes: options.baselineRuntimes,
            minimumSamples: options.minimumSamples,
            samplePhase: options.samplePhase,
            comparisons: comparisons,
            missingRequirements: missing.sorted()
        )
    }

    private static func requirementLabel(
        rule: BenchmarkClaimRule,
        workload: String,
        runtime: String,
        role: String
    ) -> String {
        if rule.resolvedCandidateWorkload == rule.workload && rule.resolvedBaselineWorkload == rule.workload {
            return "\(rule.workload) / \(runtime)"
        }
        return "\(rule.workload) \(role) \(workload) / \(runtime)"
    }

    public static func loadJSONReports(urls: [URL]) throws -> [BenchmarkResult] {
        var results: [BenchmarkResult] = []
        for url in urls {
            guard url.pathExtension.lowercased() == "json" else {
                throw ConjetError.invalidArgument("benchmark gate requires raw JSON reports, got \(url.path)")
            }
            let data = try Data(contentsOf: url)
            let decoded = try ConjetJSON.decoder().decode([BenchmarkResult].self, from: data)
            results.append(contentsOf: decoded)
        }
        return results
    }

    private static func compare(
        rule: BenchmarkClaimRule,
        baselineRuntime: String,
        candidate: Summary,
        baseline: Summary,
        minimumSamples: Int
    ) -> BenchmarkClaimComparison {
        var reasons: [String] = []
        if candidate.samples < minimumSamples {
            reasons.append("candidate has too few samples")
        }
        if baseline.samples < minimumSamples {
            reasons.append("baseline has too few samples")
        }
        if candidate.failures > 0 {
            reasons.append("candidate has \(candidate.failures) failures")
        }
        if baseline.samples >= minimumSamples,
           baseline.failures == baseline.samples,
           candidate.samples >= minimumSamples,
           candidate.failures == 0 {
            return BenchmarkClaimComparison(
                workload: rule.workload,
                candidateWorkload: rule.resolvedCandidateWorkload,
                baselineWorkload: rule.resolvedBaselineWorkload,
                measure: rule.measure.label,
                baselineRuntime: baselineRuntime,
                candidateSamples: candidate.samples,
                baselineSamples: baseline.samples,
                candidateFailures: candidate.failures,
                baselineFailures: baseline.failures,
                candidateP50: candidate.p50,
                baselineP50: baseline.p50,
                candidateP95: candidate.p95,
                baselineP95: baseline.p95,
                p50Ratio: nil,
                p95Ratio: nil,
                passed: true,
                reason: "baseline failed all samples while candidate succeeded"
            )
        }
        if baseline.failures > 0 {
            reasons.append("baseline has \(baseline.failures) failures")
        }
        if candidate.missingMeasure {
            reasons.append("candidate missing \(rule.measure.label)")
        }
        if baseline.missingMeasure {
            reasons.append("baseline missing \(rule.measure.label)")
        }

        let p50Ratio = ratio(candidate.p50, baseline.p50)
        let p95Ratio = ratio(candidate.p95, baseline.p95)
        if let p50Ratio, p50Ratio > rule.maxP50Ratio {
            reasons.append("P50 ratio \(format(p50Ratio)) exceeds \(format(rule.maxP50Ratio))")
        }
        if let p95Ratio, p95Ratio > rule.maxP95Ratio {
            reasons.append("P95 ratio \(format(p95Ratio)) exceeds \(format(rule.maxP95Ratio))")
        }
        if p50Ratio == nil {
            reasons.append("P50 ratio unavailable")
        }
        if p95Ratio == nil {
            reasons.append("P95 ratio unavailable")
        }

        return BenchmarkClaimComparison(
            workload: rule.workload,
            candidateWorkload: rule.resolvedCandidateWorkload,
            baselineWorkload: rule.resolvedBaselineWorkload,
            measure: rule.measure.label,
            baselineRuntime: baselineRuntime,
            candidateSamples: candidate.samples,
            baselineSamples: baseline.samples,
            candidateFailures: candidate.failures,
            baselineFailures: baseline.failures,
            candidateP50: candidate.p50,
            baselineP50: baseline.p50,
            candidateP95: candidate.p95,
            baselineP95: baseline.p95,
            p50Ratio: p50Ratio,
            p95Ratio: p95Ratio,
            passed: reasons.isEmpty,
            reason: reasons.isEmpty ? "passed" : reasons.joined(separator: "; ")
        )
    }

    private static func summarize(
        results: [BenchmarkResult],
        runtime: String,
        workload: String,
        measure: BenchmarkMeasure,
        samplePhase: BenchmarkSamplePhase
    ) -> Summary {
        let matching = results.filter { result in
            result.runtime == runtime &&
                result.workload == workload &&
                samplePhase.matches(result)
        }
        let failures = matching.filter { $0.exitCode != 0 }.count
        let values: [Double]
        let missingMeasure: Bool
        switch measure {
        case .durationSeconds:
            values = matching.map(\.durationSeconds)
            missingMeasure = false
        case .metric(let metric):
            let measured = matching.compactMap { $0.metrics[metric] }
            values = measured
            missingMeasure = !matching.isEmpty && measured.count != matching.count
        }

        let sorted = values.sorted()
        return Summary(
            samples: matching.count,
            failures: failures,
            p50: percentile(0.50, values: sorted),
            p95: percentile(0.95, values: sorted),
            missingMeasure: missingMeasure || matching.isEmpty
        )
    }

    private static func percentile(_ percentile: Double, values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let rank = Int(ceil(percentile * Double(values.count))) - 1
        return values[max(0, min(rank, values.count - 1))]
    }

    private static func ratio(_ candidate: Double?, _ baseline: Double?) -> Double? {
        guard let candidate, let baseline else { return nil }
        if baseline == 0 {
            return candidate == 0 ? 1 : nil
        }
        return candidate / baseline
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

private struct Summary {
    var samples: Int
    var failures: Int
    var p50: Double?
    var p95: Double?
    var missingMeasure: Bool
}

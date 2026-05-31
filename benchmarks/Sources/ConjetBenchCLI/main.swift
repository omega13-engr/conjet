import ConjetBench
import ConjetCore
import Darwin
import Dispatch
import Foundation

@main
struct ConjetBenchCLI {
    static func main() {
        do {
            try run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("conjet-bench: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run(arguments: [String]) throws {
        var args = arguments
        let command = args.first ?? "run"
        if !args.isEmpty { args.removeFirst() }

        switch command {
        case "run", "run-all", "all":
            let outcome = try runAll(args: args)
            printRunAllSummary(outcome)
            if outcome.suites.contains(where: { $0.status == "failed" }) {
                throw ConjetError.unavailable("one or more benchmark suites failed")
            }
        case "gate":
            try gate(args: args)
        case "energy-gate":
            try energyGate(args: args)
        case "help", "-h", "--help":
            printHelp()
        default:
            throw ConjetError.invalidArgument("unknown command '\(command)'")
        }
    }

    private static func runAll(args: [String]) throws -> BenchmarkRunAllOutcome {
        let contexts = value(after: "--contexts", in: args).map(csvList) ?? ["conjet", "orbstack", "colima"]
        let samples = value(after: "--samples", in: args).flatMap(Int.init) ?? 10
        let outputDirectory = URL(
            fileURLWithPath: expandedPath(value(after: "--output-dir", in: args) ?? defaultRunAllDirectory().path),
            isDirectory: true
        )
        let includeEnergy = !args.contains("--no-energy")
        let includePolyglot = !args.contains("--no-polyglot")
        let includeNoCache = !args.contains("--no-cache-suite")
        let requirePower = args.contains("--require-power")
        let commandTimeout = value(after: "--command-timeout", in: args).flatMap(Double.init) ?? 240
        let energySeconds = value(after: "--energy-seconds", in: args).flatMap(Double.init) ?? 30
        let polyglotSamples = value(after: "--polyglot-samples", in: args).flatMap(Int.init) ?? min(samples, 5)
        let ecosystems = value(after: "--ecosystems", in: args).map(csvList) ?? PolyglotBenchmarkSuite.defaultEcosystems

        try requireSudo()
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let startedAt = Date()
        let box = BenchmarkOutcomeBox()
        var jobs: [BenchmarkJob] = [
            BenchmarkJob(name: "warm-gate") {
                try runReleaseGate(
                    name: "warm-gate",
                    contexts: contexts,
                    samples: samples,
                    phase: .warm,
                    warmup: true,
                    outputDirectory: outputDirectory.appendingPathComponent("warm-gate", isDirectory: true),
                    commandTimeout: commandTimeout
                )
            },
            BenchmarkJob(name: "cold-base-prepulled-gate") {
                try runReleaseGate(
                    name: "cold-base-prepulled-gate",
                    contexts: contexts,
                    samples: samples,
                    phase: .coldBasePrepulled,
                    warmup: false,
                    outputDirectory: outputDirectory.appendingPathComponent("cold-base-prepulled-gate", isDirectory: true),
                    commandTimeout: commandTimeout
                )
            },
            BenchmarkJob(name: "topology-gate") {
                try runTopologyGate(
                    contexts: contexts,
                    samples: samples,
                    outputDirectory: outputDirectory.appendingPathComponent("topology-gate", isDirectory: true),
                    commandTimeout: commandTimeout
                )
            }
        ]

        if includeNoCache {
            jobs.append(BenchmarkJob(name: "no-cache-gate") {
                try runReleaseGate(
                    name: "no-cache-gate",
                    contexts: contexts,
                    samples: samples,
                    phase: .noCache,
                    warmup: false,
                    outputDirectory: outputDirectory.appendingPathComponent("no-cache-gate", isDirectory: true),
                    commandTimeout: commandTimeout
                )
            })
        }

        if includePolyglot {
            jobs.append(BenchmarkJob(name: "polyglot-gate") {
                try runPolyglotGate(
                    contexts: contexts,
                    samples: polyglotSamples,
                    ecosystems: ecosystems,
                    outputDirectory: outputDirectory.appendingPathComponent("polyglot-gate", isDirectory: true),
                    commandTimeout: max(commandTimeout, 300)
                )
            })
        }

        print("conjet-bench: sudo validated; running \(jobs.count) wall-time suites in parallel")
        if includeEnergy {
            print("conjet-bench: energy-gate will run after parallel suites to keep power samples isolated")
        }
        let group = DispatchGroup()
        for job in jobs {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let suiteStartedAt = Date()
                do {
                    print("conjet-bench: starting \(job.name)")
                    var outcome = try job.run()
                    outcome.durationSeconds = Date().timeIntervalSince(suiteStartedAt)
                    box.append(outcome)
                    print("conjet-bench: finished \(job.name) (\(outcome.status))")
                } catch {
                    box.append(BenchmarkSuiteOutcome(
                        name: job.name,
                        status: "failed",
                        durationSeconds: Date().timeIntervalSince(suiteStartedAt),
                        outputDirectory: outputDirectory.appendingPathComponent(job.name, isDirectory: true).path,
                        reports: [:],
                        summary: String(describing: error)
                    ))
                    print("conjet-bench: failed \(job.name): \(error)")
                }
                group.leave()
            }
        }
        group.wait()

        if includeEnergy {
            let suiteStartedAt = Date()
            do {
                print("conjet-bench: starting energy-gate")
                var outcome = try runEnergyGate(
                    contexts: contexts,
                    samples: samples,
                    requirePower: requirePower,
                    outputDirectory: outputDirectory.appendingPathComponent("energy-gate", isDirectory: true),
                    seconds: energySeconds
                )
                outcome.durationSeconds = Date().timeIntervalSince(suiteStartedAt)
                box.append(outcome)
                print("conjet-bench: finished energy-gate (\(outcome.status))")
            } catch {
                box.append(BenchmarkSuiteOutcome(
                    name: "energy-gate",
                    status: "failed",
                    durationSeconds: Date().timeIntervalSince(suiteStartedAt),
                    outputDirectory: outputDirectory.appendingPathComponent("energy-gate", isDirectory: true).path,
                    reports: [:],
                    summary: String(describing: error)
                ))
                print("conjet-bench: failed energy-gate: \(error)")
            }
        }

        let suites = box.values.sorted { $0.name < $1.name }
        let outcome = BenchmarkRunAllOutcome(
            contexts: contexts,
            samples: samples,
            startedAt: startedAt,
            durationSeconds: Date().timeIntervalSince(startedAt),
            outputDirectory: outputDirectory.path,
            suites: suites
        )
        let jsonURL = outputDirectory.appendingPathComponent("run-all.json")
        try ConjetJSON.string(outcome).write(to: jsonURL, atomically: true, encoding: .utf8)
        let markdownURL = outputDirectory.appendingPathComponent("run-all.md")
        try renderRunAllMarkdown(outcome).write(to: markdownURL, atomically: true, encoding: .utf8)
        return outcome
    }

    private static func runReleaseGate(
        name: String,
        contexts: [String],
        samples: Int,
        phase: BenchmarkSamplePhase,
        warmup: Bool,
        outputDirectory: URL,
        commandTimeout: Double
    ) throws -> BenchmarkSuiteOutcome {
        let result = try BenchmarkReleaseGateRunner(
            options: BenchmarkReleaseGateOptions(
                contexts: contexts,
                candidateRuntime: "conjet",
                baselineRuntimes: contexts.filter { $0 != "conjet" },
                iterations: samples,
                minimumSamples: samples,
                warmup: warmup,
                samplePhase: phase,
                includeIdle: false,
                includePower: false,
                dockerCommandTimeoutSeconds: commandTimeout
            )
        ).run(outputDirectory: outputDirectory)

        return BenchmarkSuiteOutcome(
            name: name,
            status: result.gateReport.passed ? "passed" : "failed",
            durationSeconds: 0,
            outputDirectory: outputDirectory.path,
            reports: [
                "docker": result.artifacts.dockerReport,
                "all-results": result.artifacts.allResultsReport,
                "gate": result.artifacts.gateReport,
                "gate-markdown": result.artifacts.gateMarkdownReport
            ],
            summary: result.gateReport.passed ? "gate passed" : "gate failed"
        )
    }

    private static func runTopologyGate(
        contexts: [String],
        samples: Int,
        outputDirectory: URL,
        commandTimeout: Double
    ) throws -> BenchmarkSuiteOutcome {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let workDirectory = outputDirectory.appendingPathComponent("work", isDirectory: true)
        let workloads = [
            "strict-bind-npm-install",
            "smart-bind-npm-install",
            "volume-npm-install",
            "conjetfs-npm-install",
            "strict-bind-pnpm-install",
            "smart-bind-pnpm-install",
            "volume-pnpm-install",
            "conjetfs-pnpm-install",
            "strict-bind-cargo-build",
            "smart-bind-cargo-build",
            "volume-cargo-build",
            "conjetfs-cargo-build",
            "strict-bind-hot-reload",
            "smart-bind-hot-reload",
            "conjetfs-hot-reload"
        ]
        let results = try DockerBenchmarkSuite(
            contexts: contexts,
            iterations: samples,
            warmup: true,
            samplePhase: .warm,
            workloads: workloads,
            commandTimeoutSeconds: commandTimeout
        ).run(workDirectory: workDirectory)
        let allResults = outputDirectory.appendingPathComponent("all-results.json")
        try ConjetJSON.string(results).write(to: allResults, atomically: true, encoding: .utf8)
        let report = outputDirectory.appendingPathComponent("topology-gate.md")
        try renderTopologyMarkdown(results).write(to: report, atomically: true, encoding: .utf8)
        let failures = results.filter { $0.exitCode != 0 }.count
        return BenchmarkSuiteOutcome(
            name: "topology-gate",
            status: failures == 0 ? "measured" : "failed",
            durationSeconds: 0,
            outputDirectory: outputDirectory.path,
            reports: ["all-results": allResults.path, "markdown": report.path],
            summary: failures == 0 ? "topology results measured" : "\(failures) topology samples failed"
        )
    }

    private static func runPolyglotGate(
        contexts: [String],
        samples: Int,
        ecosystems: [String],
        outputDirectory: URL,
        commandTimeout: Double
    ) throws -> BenchmarkSuiteOutcome {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let workDirectory = outputDirectory.appendingPathComponent("work", isDirectory: true)
        let results = try PolyglotBenchmarkSuite(
            contexts: contexts,
            samples: samples,
            ecosystems: ecosystems,
            topology: "smart-bind",
            commandTimeoutSeconds: commandTimeout
        ).run(workDirectory: workDirectory)
        let allResults = outputDirectory.appendingPathComponent("all-results.json")
        try ConjetJSON.string(results).write(to: allResults, atomically: true, encoding: .utf8)
        let report = outputDirectory.appendingPathComponent("polyglot-gate.md")
        try renderPolyglotMarkdown(results: results, ecosystems: ecosystems)
            .write(to: report, atomically: true, encoding: .utf8)
        let failures = results.filter { $0.exitCode != 0 }.count
        return BenchmarkSuiteOutcome(
            name: "polyglot-gate",
            status: failures == 0 ? "measured" : "failed",
            durationSeconds: 0,
            outputDirectory: outputDirectory.path,
            reports: ["all-results": allResults.path, "markdown": report.path],
            summary: failures == 0 ? "polyglot results measured" : "\(failures) polyglot samples failed"
        )
    }

    private static func runEnergyGate(
        contexts: [String],
        samples: Int,
        requirePower: Bool,
        outputDirectory: URL,
        seconds: Double
    ) throws -> BenchmarkSuiteOutcome {
        let result = try BenchmarkEnergyGateRunner(
            options: BenchmarkEnergyGateOptions(
                contexts: contexts,
                samples: samples,
                requirePower: requirePower,
                useSudo: true,
                seconds: seconds
            )
        ).run(outputDirectory: outputDirectory)
        return BenchmarkSuiteOutcome(
            name: "energy-gate",
            status: result.powermetricsAvailable ? "measured" : "skipped",
            durationSeconds: 0,
            outputDirectory: outputDirectory.path,
            reports: [
                "all-results": result.allResultsReport,
                "markdown": result.markdownReport
            ],
            summary: result.skippedReason ?? "energy results measured"
        )
    }

    private static func gate(args: [String]) throws {
        guard let reportPaths = value(after: "--reports", in: args) else {
            throw ConjetError.invalidArgument("usage: conjet-bench gate --reports report.json[,report2.json] [--candidate conjet] [--baselines orbstack,colima] [--min-samples N]")
        }
        let urls = reportPaths.split(separator: ",").map { URL(fileURLWithPath: expandedPath(String($0))) }
        let candidate = value(after: "--candidate", in: args) ?? "conjet"
        let baselines = value(after: "--baselines", in: args).map(csvList) ?? ["orbstack", "colima"]
        let minSamples = value(after: "--min-samples", in: args).flatMap(Int.init) ?? 10
        let phase = try samplePhase(value(after: "--phase", in: args))
        let results = try BenchmarkClaimGate.loadJSONReports(urls: urls)
        let report = BenchmarkClaimGate.evaluate(
            results: results,
            options: BenchmarkClaimGateOptions(
                candidateRuntime: candidate,
                baselineRuntimes: baselines,
                minimumSamples: minSamples,
                samplePhase: phase,
                rules: BenchmarkClaimGateOptions.defaultRules
            )
        )
        if args.contains("--markdown") {
            print(BenchmarkClaimGateMarkdownReport.render(report))
        } else {
            print(try ConjetJSON.string(report))
        }
        if !report.passed {
            throw ConjetError.unavailable("benchmark gate failed")
        }
    }

    private static func energyGate(args: [String]) throws {
        try requireSudo()
        let outputDirectory = URL(
            fileURLWithPath: expandedPath(value(after: "--output-dir", in: args) ?? defaultRunAllDirectory().path),
            isDirectory: true
        )
        let result = try BenchmarkEnergyGateRunner(
            options: BenchmarkEnergyGateOptions(
                contexts: value(after: "--contexts", in: args).map(csvList) ?? ["conjet", "orbstack", "colima"],
                workloads: value(after: "--workloads", in: args).map(csvList) ?? ["idle", "container-start-loop", "hot-reload-loop", "compose-loop", "npm-install", "pnpm-install", "cargo-build"],
                samples: value(after: "--samples", in: args).flatMap(Int.init) ?? 10,
                requirePower: args.contains("--require-power"),
                useSudo: true,
                seconds: value(after: "--seconds", in: args).flatMap(Double.init) ?? 30,
                minimumActiveSeconds: value(after: "--min-active-seconds", in: args).flatMap(Double.init) ?? 10,
                workloadTimeoutSeconds: value(after: "--workload-timeout", in: args).flatMap(Double.init) ?? 180,
                prepullImages: !args.contains("--no-prepull")
            )
        ).run(outputDirectory: outputDirectory)
        print("energy gate: \(result.powermetricsAvailable ? "measured" : "skipped")")
        if let skippedReason = result.skippedReason {
            print("  reason: \(skippedReason)")
        }
        print("  results: \(result.allResultsReport)")
        print("  report: \(result.markdownReport)")
    }

    private static func requireSudo() throws {
        print("conjet-bench: validating sudo with sudo -v")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-v"]
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ConjetError.unavailable("sudo -v failed; benchmarks require a valid sudo timestamp")
        }
    }

    private static func samplePhase(_ value: String?) throws -> BenchmarkSamplePhase {
        guard let value else { return .any }
        guard let phase = BenchmarkSamplePhase(rawValue: value) else {
            throw ConjetError.invalidArgument("invalid phase '\(value)'")
        }
        return phase
    }

    private static func renderTopologyMarkdown(_ results: [BenchmarkResult]) -> String {
        [
            "# Conjet Topology Gate",
            "",
            "strict-bind is maximum compatibility and may be slower.",
            "smart-bind/native-overlay is Conjet's optimized topology candidate.",
            "conjetfs is the fast-path synchronized workspace.",
            "volume is the Linux-native baseline.",
            "",
            BenchmarkMarkdownReport.render(results: results, title: "Topology Results")
        ].joined(separator: "\n")
    }

    private static func renderPolyglotMarkdown(results: [BenchmarkResult], ecosystems: [String]) -> String {
        [
            "# Conjet Polyglot Gate",
            "",
            "- Ecosystems: \(ecosystems.joined(separator: ", "))",
            "- Topology: smart-bind",
            "",
            BenchmarkMarkdownReport.render(results: results, title: "Polyglot Results")
        ].joined(separator: "\n")
    }

    private static func renderRunAllMarkdown(_ outcome: BenchmarkRunAllOutcome) -> String {
        var lines = [
            "# Conjet Benchmark Run",
            "",
            "- Contexts: \(outcome.contexts.joined(separator: ", "))",
            "- Samples: \(outcome.samples)",
            "- Output: \(outcome.outputDirectory)",
            "- Duration: \(String(format: "%.3f", outcome.durationSeconds))s",
            "",
            "| Suite | Status | Duration | Summary | Output |",
            "| --- | --- | ---: | --- | --- |"
        ]
        for suite in outcome.suites {
            lines.append("| \(suite.name) | \(suite.status) | \(String(format: "%.3f", suite.durationSeconds))s | \(suite.summary) | \(suite.outputDirectory) |")
        }
        return lines.joined(separator: "\n")
    }

    private static func printRunAllSummary(_ outcome: BenchmarkRunAllOutcome) {
        print("conjet-bench: run complete")
        print("  contexts: \(outcome.contexts.joined(separator: ", "))")
        print("  output: \(outcome.outputDirectory)")
        for suite in outcome.suites {
            print("  \(suite.name): \(suite.status) - \(suite.summary)")
        }
    }

    private static func printHelp() {
        print(
            """
            conjet-bench - research-grade benchmark runner for Conjet

            Usage:
              conjet-bench run [options]
              conjet-bench energy-gate [options]
              conjet-bench gate --reports PATH[,PATH...]

            Commands:
              run          Run wall-time suites in parallel, then run energy in isolation.
              energy-gate  Run only the powermetrics energy gate.
              gate         Score existing raw JSON reports.
              help         Show this help text.

            Run options:
              --contexts LIST          Docker contexts to measure (default: conjet,orbstack,colima)
              --samples N              Samples per wall-time workload (default: 10)
              --polyglot-samples N     Samples per polyglot workload (default: min(samples, 5))
              --ecosystems LIST        js,python,jvm,dotnet,go,rust,cpp
              --output-dir DIR         Report root (default: benchmarks/reports/run-all-YYYYMMDD-HHMMSS)
              --command-timeout N      Docker workload timeout in seconds (default: 240)
              --energy-seconds N       Idle energy sample duration (default: 30)
              --require-power          Fail energy suite if powermetrics cannot measure
              --no-energy              Skip energy gate
              --no-polyglot            Skip polyglot gate
              --no-cache-suite         Skip no-cache gate

            Notes:
              run always executes sudo -v before starting benchmark suites.
              Kubernetes is intentionally out of scope for this benchmark generation.
            """
        )
    }

    private static func csvList(_ value: String) -> [String] {
        value
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }

    private static func expandedPath(_ value: String) -> String {
        if value == "~" {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        if value.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(value.dropFirst(2)))
                .path
        }
        return value
    }

    private static func defaultRunAllDirectory(now: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("benchmarks", isDirectory: true)
            .appendingPathComponent("reports", isDirectory: true)
            .appendingPathComponent("run-all-\(formatter.string(from: now))", isDirectory: true)
    }
}

private struct BenchmarkJob: Sendable {
    var name: String
    var run: @Sendable () throws -> BenchmarkSuiteOutcome
}

private final class BenchmarkOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [BenchmarkSuiteOutcome] = []

    var values: [BenchmarkSuiteOutcome] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ outcome: BenchmarkSuiteOutcome) {
        lock.lock()
        storage.append(outcome)
        lock.unlock()
    }
}

private struct BenchmarkRunAllOutcome: Codable, Sendable {
    var contexts: [String]
    var samples: Int
    var startedAt: Date
    var durationSeconds: Double
    var outputDirectory: String
    var suites: [BenchmarkSuiteOutcome]
}

private struct BenchmarkSuiteOutcome: Codable, Sendable {
    var name: String
    var status: String
    var durationSeconds: Double
    var outputDirectory: String
    var reports: [String: String]
    var summary: String
}

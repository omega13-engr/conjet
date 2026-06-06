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
        case "memory-gate":
            try memoryGate(args: args)
        case "clock-gate":
            try clockGate(args: args)
        case "ssh-gate":
            try sshGate(args: args)
        case "ipv6-gate":
            try ipv6Gate(args: args)
        case "network-gate":
            try networkGate(args: args)
        case "network-segments":
            try networkSegments(args: args)
        case "help", "-h", "--help":
            printHelp()
        default:
            throw ConjetError.invalidArgument("unknown command '\(command)'")
        }
    }

    private static func runAll(args: [String]) throws -> BenchmarkRunAllOutcome {
        let contexts = value(after: "--contexts", in: args).map(csvList) ?? ["conjet", "orbstack", "colima"]
        let samples = benchmarkSamples()
        let outputDirectory = URL(
            fileURLWithPath: expandedPath(value(after: "--output-dir", in: args) ?? defaultRunAllDirectory().path),
            isDirectory: true
        )
        let selectedSuites = try runAllSuiteSelection(value(after: "--suites", in: args))
        let includeEnergy = suiteIsSelected("energy-gate", selectedSuites: selectedSuites) && !args.contains("--no-energy")
        let includePolyglot = suiteIsSelected("polyglot-gate", selectedSuites: selectedSuites) && !args.contains("--no-polyglot")
        let includeNoCache = suiteIsSelected("no-cache-gate", selectedSuites: selectedSuites) && !args.contains("--no-cache-suite")
        let includeNetwork = suiteIsSelected("network-gate", selectedSuites: selectedSuites) && !args.contains("--no-network")
        let cleanupWork = !args.contains("--keep-work")
        let requirePower = args.contains("--require-power")
        let commandTimeout = value(after: "--command-timeout", in: args).flatMap(Double.init) ?? 240
        let energySeconds = value(after: "--energy-seconds", in: args).flatMap(Double.init) ?? 10
        let energySamples = benchmarkSamples()
        let polyglotSamples = benchmarkSamples()
        let ecosystems = value(after: "--ecosystems", in: args).map(csvList) ?? PolyglotBenchmarkSuite.defaultEcosystems
        let resourceScope = benchmarkResourceScope(outputDirectory: outputDirectory)

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let startedAt = Date()
        let box = BenchmarkOutcomeBox()
        var jobs: [BenchmarkJob] = []
        if suiteIsSelected("warm-gate", selectedSuites: selectedSuites) {
            jobs.append(BenchmarkJob(name: "warm-gate") {
                try runReleaseGate(
                    name: "warm-gate",
                    contexts: contexts,
                    samples: samples,
                    phase: .warm,
                    warmup: true,
                    outputDirectory: outputDirectory.appendingPathComponent("warm-gate", isDirectory: true),
                    commandTimeout: commandTimeout,
                    resourceScope: "\(resourceScope)-warm-gate",
                    cleanupWork: cleanupWork
                )
            })
        }
        if suiteIsSelected("cold-base-prepulled-gate", selectedSuites: selectedSuites) {
            jobs.append(BenchmarkJob(name: "cold-base-prepulled-gate") {
                try runReleaseGate(
                    name: "cold-base-prepulled-gate",
                    contexts: contexts,
                    samples: samples,
                    phase: .coldBasePrepulled,
                    warmup: false,
                    outputDirectory: outputDirectory.appendingPathComponent("cold-base-prepulled-gate", isDirectory: true),
                    commandTimeout: commandTimeout,
                    resourceScope: "\(resourceScope)-cold-base-prepulled-gate",
                    cleanupWork: cleanupWork
                )
            })
        }
        if suiteIsSelected("topology-gate", selectedSuites: selectedSuites) {
            jobs.append(BenchmarkJob(name: "topology-gate") {
                try runTopologyGate(
                    contexts: contexts,
                    samples: samples,
                    outputDirectory: outputDirectory.appendingPathComponent("topology-gate", isDirectory: true),
                    commandTimeout: commandTimeout,
                    resourceScope: "\(resourceScope)-topology-gate",
                    cleanupWork: cleanupWork
                )
            })
        }

        if includeNoCache {
            jobs.append(BenchmarkJob(name: "no-cache-gate") {
                try runReleaseGate(
                    name: "no-cache-gate",
                    contexts: contexts,
                    samples: samples,
                    phase: .noCache,
                    warmup: false,
                    outputDirectory: outputDirectory.appendingPathComponent("no-cache-gate", isDirectory: true),
                    commandTimeout: commandTimeout,
                    resourceScope: "\(resourceScope)-no-cache-gate",
                    cleanupWork: cleanupWork
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
                    commandTimeout: max(commandTimeout, 300),
                    resourceScope: "\(resourceScope)-polyglot-gate",
                    cleanupWork: cleanupWork
                )
            })
        }

        if includeNetwork {
            jobs.append(BenchmarkJob(name: "network-gate") {
                try runNetworkGate(
                    contexts: contexts,
                    samples: samples,
                    workloads: value(after: "--network-workloads", in: args).map(csvList) ?? NetworkBenchmarkSuite.defaultWorkloads,
                    outputDirectory: outputDirectory.appendingPathComponent("network-gate", isDirectory: true),
                    commandTimeout: min(max(commandTimeout, 60), 180)
                )
            })
        }

        if includeEnergy {
            let suiteStartedAt = Date()
            do {
                try requireSudo()
                print("conjet-bench: sudo validated; starting energy-gate before wall-time suites")
                var outcome = try runEnergyGate(
                    contexts: contexts,
                    energySamples: energySamples,
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

        guard includeEnergy || !jobs.isEmpty else {
            throw ConjetError.invalidArgument("no benchmark suites selected")
        }

        print("conjet-bench: running \(jobs.count) wall-time suites in parallel")
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
        if cleanupWork {
            cleanupBenchmarkDumps(in: outputDirectory)
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
        commandTimeout: Double,
        resourceScope: String,
        cleanupWork: Bool
    ) throws -> BenchmarkSuiteOutcome {
        defer {
            if cleanupWork {
                cleanupBenchmarkDumps(in: outputDirectory)
            }
        }
        let result = try BenchmarkReleaseGateRunner(
            options: BenchmarkReleaseGateOptions(
                contexts: contexts,
                candidateRuntime: "conjet",
                baselineRuntimes: contexts.filter { $0 != "conjet" },
                requiredBaselineRuntimes: requiredBaselines(from: contexts),
                iterations: samples,
                minimumSamples: samples,
                warmup: warmup,
                samplePhase: phase,
                includeIdle: false,
                includePower: false,
                dockerCommandTimeoutSeconds: commandTimeout,
                dockerResourceScope: resourceScope
            )
        ).run(outputDirectory: outputDirectory)
        let advisoryFailures = result.gateReport.comparisons.filter { !$0.requiredBaseline && !$0.passed }.count
        let summary: String
        if result.gateReport.passed && advisoryFailures > 0 {
            summary = "required gate passed; \(advisoryFailures) advisory comparisons failed"
        } else {
            summary = result.gateReport.passed ? "gate passed" : "gate failed"
        }

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
            summary: summary
        )
    }

    private static func runTopologyGate(
        contexts: [String],
        samples: Int,
        outputDirectory: URL,
        commandTimeout: Double,
        resourceScope: String,
        cleanupWork: Bool
    ) throws -> BenchmarkSuiteOutcome {
        defer {
            if cleanupWork {
                cleanupBenchmarkDumps(in: outputDirectory)
            }
        }
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
            commandTimeoutSeconds: commandTimeout,
            resourceScope: resourceScope
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
        commandTimeout: Double,
        resourceScope: String,
        cleanupWork: Bool
    ) throws -> BenchmarkSuiteOutcome {
        defer {
            if cleanupWork {
                cleanupBenchmarkDumps(in: outputDirectory)
            }
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let workDirectory = outputDirectory.appendingPathComponent("work", isDirectory: true)
        let results = try PolyglotBenchmarkSuite(
            contexts: contexts,
            samples: samples,
            ecosystems: ecosystems,
            topology: "smart-bind",
            commandTimeoutSeconds: commandTimeout,
            resourceScope: resourceScope
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
        energySamples: Int,
        requirePower: Bool,
        outputDirectory: URL,
        seconds: Double
    ) throws -> BenchmarkSuiteOutcome {
        let result = try BenchmarkEnergyGateRunner(
            options: BenchmarkEnergyGateOptions(
                contexts: contexts,
                samples: energySamples,
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

    private static func runNetworkGate(
        contexts: [String],
        samples: Int,
        workloads: [String],
        outputDirectory: URL,
        commandTimeout: Double,
        runtimeLabels: [String: String] = [:],
        proxyEngineLabels: [String: String] = [:]
    ) throws -> BenchmarkSuiteOutcome {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let results = try NetworkBenchmarkSuite(
            options: NetworkBenchmarkOptions(
                contexts: contexts,
                samples: samples,
                commandTimeoutSeconds: commandTimeout,
                workloads: workloads,
                runtimeLabels: runtimeLabels,
                proxyEngineLabels: proxyEngineLabels
            )
        ).run(outputDirectory: outputDirectory)
        let allResults = outputDirectory.appendingPathComponent("all-results.json")
        try ConjetJSON.string(results).write(to: allResults, atomically: true, encoding: .utf8)
        let report = outputDirectory.appendingPathComponent("network-gate.md")
        let markdown = renderNetworkMarkdown(results: results, contexts: contexts, workloads: workloads)
        try markdown.write(to: report, atomically: true, encoding: .utf8)
        let finalReport = outputDirectory.appendingPathComponent("REPORT.md")
        try markdown.write(to: finalReport, atomically: true, encoding: .utf8)
        let suiteStatus = networkSuiteStatus(results)
        return BenchmarkSuiteOutcome(
            name: "network-gate",
            status: suiteStatus.status,
            durationSeconds: 0,
            outputDirectory: outputDirectory.path,
            reports: ["all-results": allResults.path, "markdown": report.path, "report": finalReport.path],
            summary: suiteStatus.summary
        )
    }

    private static func gate(args: [String]) throws {
        guard let reportPaths = value(after: "--reports", in: args) else {
            throw ConjetError.invalidArgument("usage: conjet-bench gate --reports report.json[,report2.json] [--candidate conjet] [--baselines orbstack,colima] [--required-baselines orbstack] [--min-samples N]")
        }
        let urls = reportPaths.split(separator: ",").map { URL(fileURLWithPath: expandedPath(String($0))) }
        let candidate = value(after: "--candidate", in: args) ?? "conjet"
        let baselines = value(after: "--baselines", in: args).map(csvList) ?? ["orbstack", "colima"]
        let requiredBaselines = value(after: "--required-baselines", in: args).map(csvList) ?? baselines
        let minSamples = value(after: "--min-samples", in: args).flatMap(Int.init) ?? 10
        let phase = try samplePhase(value(after: "--phase", in: args))
        let results = try BenchmarkClaimGate.loadJSONReports(urls: urls)
        let rules = rulesRepresented(in: results)
        let report = BenchmarkClaimGate.evaluate(
            results: results,
            options: BenchmarkClaimGateOptions(
                candidateRuntime: candidate,
                baselineRuntimes: baselines,
                requiredBaselineRuntimes: requiredBaselines,
                minimumSamples: minSamples,
                samplePhase: phase,
                rules: rules
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
                samples: benchmarkSamples(),
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

    private static func memoryGate(args: [String]) throws {
        let startedAt = Date()
        if args.contains("--start") {
            _ = try runProcess(["/usr/bin/env", "swift", "run", "conjet", "start"], timeoutSeconds: 300)
        }
        let config = try ConjetConfig.loadOrCreate()
        let policy = config.memoryPolicy
        var metrics = BenchmarkMetrics()
        metrics["configured_memory_mib"] = Double(config.memoryMiB)
        metrics["recommended_memory_mib"] = Double(policy.recommendedMemoryMiB)
        metrics.setString(policy.profile.rawValue, for: "memory_profile")
        metrics.setBool(policy.lazyRuntimeServices, for: "lazy_runtime_services")
        metrics.setBool(policy.lazyNetworkHelpers, for: "lazy_network_helpers")
        metrics["helper_reclaim_seconds"] = Double(policy.reclaimIdleHelpersAfterSeconds)
        metrics["idle_wakeup_budget_per_sec"] = policy.idleWakeupBudgetPerSecond
        metrics["conjetd_rss_mb"] = hostRSSMiB(processName: "conjetd") ?? 0
        metrics["conjet_cli_rss_mb"] = hostRSSMiB(processName: "conjet") ?? 0
        metrics["network_helper_rss_mb"] = hostRSSMiB(processName: "conjet-netd") ?? 0
        if FileManager.default.fileExists(atPath: ConjetPaths.default().dockerSocket.path) {
            metrics.merge(try guestRSSMetrics())
            if args.contains("--first-container") {
                metrics["time_to_first_container"] = try measureFirstContainerSeconds()
            }
        }
        let passed = config.memoryMiB >= 512
        let result = BenchmarkResult(
            workload: "memory-gate",
            runtime: "conjet",
            command: CommandLine.arguments,
            startedAt: startedAt,
            durationSeconds: Date().timeIntervalSince(startedAt),
            exitCode: passed ? 0 : 1,
            metrics: metrics,
            machine: MachineProfiler.capture(),
            stdoutTail: "memory profile \(policy.profile.rawValue)",
            stderrTail: passed ? "" : "configured memory below supported minimum"
        )
        try emitSingleGateResult(result, args: args)
        guard passed else { throw ConjetError.unavailable("memory gate failed") }
    }

    private static func clockGate(args: [String]) throws {
        let startedAt = Date()
        if args.contains("--start") {
            _ = try runProcess(["/usr/bin/env", "swift", "run", "conjet", "start"], timeoutSeconds: 300)
        }
        let repair = args.contains("--repair")
        let before = try clockProbe()
        var after = before
        var repairLatencyMs: Double?
        if abs(before.deltaMs) > 100, repair {
            let repairStartedAt = Date()
            _ = try repairGuestClockForGate()
            repairLatencyMs = Date().timeIntervalSince(repairStartedAt) * 1000
            after = try clockProbe()
        }
        var metrics = BenchmarkMetrics()
        metrics["host_guest_clock_delta_ms"] = Double(before.deltaMs)
        metrics["delta_after_repair_ms"] = Double(after.deltaMs)
        if let repairLatencyMs {
            metrics["resync_latency_ms"] = repairLatencyMs
        }
        metrics.setBool(repair, for: "repair_requested")
        let passed = abs(after.deltaMs) <= 100
        let result = BenchmarkResult(
            workload: "clock-gate",
            runtime: "conjet",
            command: CommandLine.arguments,
            startedAt: startedAt,
            durationSeconds: Date().timeIntervalSince(startedAt),
            exitCode: passed ? 0 : 1,
            metrics: metrics,
            machine: MachineProfiler.capture(),
            stdoutTail: "clock delta \(after.deltaMs) ms",
            stderrTail: passed ? "" : "clock drift exceeds 100 ms"
        )
        try emitSingleGateResult(result, args: args)
        guard passed else { throw ConjetError.unavailable("clock gate failed") }
    }

    private static func sshGate(args: [String]) throws {
        let startedAt = Date()
        if args.contains("--start") {
            _ = try runProcess(["/usr/bin/env", "swift", "run", "conjet", "start"], timeoutSeconds: 300)
        }
        let status = try runProcess(["/usr/bin/env", "swift", "run", "conjet", "ssh", "status", "--json"], timeoutSeconds: 240)
        var metrics = BenchmarkMetrics()
        metrics.setBool(status.succeeded, for: "ssh_status_command_ok")
        let keyExists = jsonBoolField("keyExists", in: status.stdout) == true
        let guestConfigured = jsonBoolField("guestConfigured", in: status.stdout) == true
        let sshdRunning = jsonBoolField("sshdRunning", in: status.stdout) == true
        let localhostOnly = jsonBoolField("localhostOnly", in: status.stdout) == true
        let endpointReachable = jsonStringField("endpoint", in: status.stdout) != nil
        let disabledModeOK = args.contains("--check-disabled-mode") ? try sshDisabledModeCheck(originalStatusJSON: status.stdout) : true
        metrics.setBool(keyExists, for: "ssh_key_exists")
        metrics.setBool(guestConfigured, for: "guest_authorized_key_configured")
        metrics.setBool(sshdRunning, for: "guest_sshd_running")
        metrics.setBool(localhostOnly, for: "localhost_only")
        metrics.setBool(endpointReachable, for: "localhost_endpoint_reachable")
        metrics.setBool(disabledModeOK, for: "ssh_disabled_mode_ok")
        let requireEndpoint = args.contains("--require-endpoint")
        let passed = status.succeeded
            && keyExists
            && guestConfigured
            && sshdRunning
            && localhostOnly
            && disabledModeOK
            && (!requireEndpoint || endpointReachable)
        let result = BenchmarkResult(
            workload: "ssh-gate",
            runtime: "conjet",
            command: CommandLine.arguments,
            startedAt: startedAt,
            durationSeconds: Date().timeIntervalSince(startedAt),
            exitCode: passed ? 0 : 1,
            metrics: metrics,
            machine: MachineProfiler.capture(),
            stdoutTail: status.stdout,
            stderrTail: passed ? "" : status.stderr
        )
        try emitSingleGateResult(result, args: args)
        guard passed else { throw ConjetError.unavailable("ssh gate failed") }
    }

    private static func ipv6Gate(args: [String]) throws {
        let startedAt = Date()
        if args.contains("--start") {
            _ = try runProcess(["/usr/bin/env", "swift", "run", "conjet", "start"], timeoutSeconds: 300)
        }
        let socket = ConjetPaths.default().dockerSocket.path
        guard FileManager.default.fileExists(atPath: socket) else {
            throw ConjetError.unavailable("Conjet Docker socket is not available; rerun with --start")
        }
        let port = Int.random(in: 20_000...40_000)
        let udpPort = Int.random(in: 40_001...55_000)
        let containerName = "conjet-ipv6-gate-\(UUID().uuidString.prefix(8))"
        let udpContainerName = "\(containerName)-udp"
        _ = try? runProcess(["/usr/bin/env", "docker", "--host", "unix://\(socket)", "rm", "-f", containerName], timeoutSeconds: 10)
        _ = try? runProcess(["/usr/bin/env", "docker", "--host", "unix://\(socket)", "rm", "-f", udpContainerName], timeoutSeconds: 10)
        defer {
            _ = try? runProcess(["/usr/bin/env", "docker", "--host", "unix://\(socket)", "rm", "-f", containerName], timeoutSeconds: 10)
            _ = try? runProcess(["/usr/bin/env", "docker", "--host", "unix://\(socket)", "rm", "-f", udpContainerName], timeoutSeconds: 10)
        }
        let run = try runProcess([
            "/usr/bin/env", "docker", "--host", "unix://\(socket)",
            "run", "-d", "--name", containerName,
            "-p", "[::1]:\(port):80",
            "nginx:alpine"
        ], timeoutSeconds: 120)
        var metrics = BenchmarkMetrics()
        metrics.setBool(run.succeeded, for: "container_started")
        Thread.sleep(forTimeInterval: 2)
        let curl6 = try runProcess(["/usr/bin/curl", "-g", "-6", "--max-time", "5", "http://[::1]:\(port)/"], timeoutSeconds: 10)
        metrics.setBool(curl6.succeeded, for: "ipv6_loopback_tcp_ok")
        metrics["published_tcp_port"] = Double(port)
        let udpRun = try runProcess([
            "/usr/bin/env", "docker", "--host", "unix://\(socket)",
            "run", "-d", "--name", udpContainerName,
            "-p", "[::1]:\(udpPort):5353/udp",
            "python:3-alpine",
            "python3", "-u", "-c",
            """
            import socket
            s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
            s.bind(('0.0.0.0',5353))
            while True:
             data,addr=s.recvfrom(2048)
             s.sendto(data,addr)
            """
        ], timeoutSeconds: 120)
        Thread.sleep(forTimeInterval: 2)
        let udpOK = udpRun.succeeded && ipv6UDPEcho(port: udpPort, payload: "conjet-ipv6-udp")
        metrics.setBool(udpRun.succeeded, for: "udp_container_started")
        metrics.setBool(udpOK, for: "ipv6_loopback_udp_ok")
        metrics["published_udp_port"] = Double(udpPort)
        let passed = run.succeeded && curl6.succeeded && udpOK
        let result = BenchmarkResult(
            workload: "ipv6-gate",
            runtime: "conjet",
            command: CommandLine.arguments,
            startedAt: startedAt,
            durationSeconds: Date().timeIntervalSince(startedAt),
            exitCode: passed ? 0 : 1,
            metrics: metrics,
            machine: MachineProfiler.capture(),
            stdoutTail: curl6.stdout,
            stderrTail: [run.stderr, curl6.stderr, udpRun.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        )
        try emitSingleGateResult(result, args: args)
        guard passed else { throw ConjetError.unavailable("ipv6 gate failed") }
    }

    private static func networkGate(args: [String]) throws {
        let contexts = value(after: "--contexts", in: args).map(csvList) ?? ["conjet", "orbstack", "colima"]
        let samples = benchmarkSamples()
        let outputDirectory = URL(
            fileURLWithPath: expandedPath(value(after: "--output-dir", in: args) ?? "benchmarks/reports/network-gate-local"),
            isDirectory: true
        )
        var workloads = value(after: "--workloads", in: args).map(csvList) ?? NetworkBenchmarkSuite.defaultWorkloads
        if args.contains("--skip-udp") {
            workloads.removeAll { $0 == "udp-echo-latency" || $0.hasPrefix("udp-echo-") || $0 == "udp-throughput" || $0 == "udp-packet-loss" }
        }
        if let proxyEngines = value(after: "--proxy-engines", in: args).map(csvList), !proxyEngines.isEmpty {
            let outcome = try runProxyEngineComparison(
                proxyEngines: proxyEngines,
                samples: samples,
                workloads: workloads,
                outputDirectory: outputDirectory,
                commandTimeout: value(after: "--command-timeout", in: args).flatMap(Double.init) ?? 90
            )
            print("network proxy-engine gate: \(outcome.status)")
            print("  results: \(outcome.reports["all-results"] ?? "")")
            print("  report: \(outcome.reports["markdown"] ?? "")")
            if outcome.status == "failed" {
                throw ConjetError.unavailable(outcome.summary)
            }
            return
        }
        if let bridgeEngines = value(after: "--bridge-engines", in: args).map(csvList), !bridgeEngines.isEmpty {
            let outcome = try runBridgeEngineComparison(
                bridgeEngines: bridgeEngines,
                samples: samples,
                workloads: workloads,
                outputDirectory: outputDirectory,
                commandTimeout: value(after: "--command-timeout", in: args).flatMap(Double.init) ?? 90
            )
            print("network bridge-engine gate: \(outcome.status)")
            print("  results: \(outcome.reports["all-results"] ?? "")")
            print("  report: \(outcome.reports["markdown"] ?? "")")
            if outcome.status == "failed" {
                throw ConjetError.unavailable(outcome.summary)
            }
            return
        }
        let outcome = try runNetworkGate(
            contexts: contexts,
            samples: samples,
            workloads: workloads,
            outputDirectory: outputDirectory,
            commandTimeout: value(after: "--command-timeout", in: args).flatMap(Double.init) ?? 90
        )
        print("network gate: \(outcome.status)")
        print("  results: \(outcome.reports["all-results"] ?? "")")
        print("  report: \(outcome.reports["markdown"] ?? "")")
        if outcome.status == "failed" {
            throw ConjetError.unavailable(outcome.summary)
        }
    }

    private static func networkSegments(args: [String]) throws {
        let contexts = value(after: "--contexts", in: args).map(csvList) ?? ["conjet"]
        let samples = benchmarkSamples()
        let workloads = value(after: "--workloads", in: args).map(csvList) ?? NetworkSegmentBenchmarkSuite.defaultWorkloads
        let outputDirectory = URL(
            fileURLWithPath: expandedPath(value(after: "--output-dir", in: args) ?? "benchmarks/reports/network-segments"),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let results = try NetworkSegmentBenchmarkSuite(
            options: NetworkSegmentBenchmarkOptions(
                contexts: contexts,
                samples: samples,
                commandTimeoutSeconds: value(after: "--command-timeout", in: args).flatMap(Double.init) ?? 90,
                workloads: workloads
            )
        ).run(outputDirectory: outputDirectory)
        let allResults = outputDirectory.appendingPathComponent("all-results.json")
        try ConjetJSON.string(results).write(to: allResults, atomically: true, encoding: .utf8)
        let markdown = renderNetworkSegmentsMarkdown(results: results, contexts: contexts, workloads: workloads)
        let report = outputDirectory.appendingPathComponent("network-segments.md")
        try markdown.write(to: report, atomically: true, encoding: .utf8)
        try markdown.write(to: outputDirectory.appendingPathComponent("REPORT.md"), atomically: true, encoding: .utf8)
        print("network segments: measured")
        print("  results: \(allResults.path)")
        print("  report: \(report.path)")
    }

    private static func runProxyEngineComparison(
        proxyEngines: [String],
        samples: Int,
        workloads: [String],
        outputDirectory: URL,
        commandTimeout: Double
    ) throws -> BenchmarkSuiteOutcome {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var allResults: [BenchmarkResult] = []
        var failures: [String] = []
        for engine in proxyEngines {
            let canonical = canonicalProxyEngine(engine)
            let expected = expectedProxyEngineStatus(canonical)
            do {
                try restartConjetForProxyEngine(canonical, expectedStatus: expected)
                let runtime = "conjet-\(canonical)"
                let engineResults = try NetworkBenchmarkSuite(
                    options: NetworkBenchmarkOptions(
                        contexts: ["conjet"],
                        samples: samples,
                        commandTimeoutSeconds: commandTimeout,
                        workloads: workloads,
                        runtimeLabels: ["conjet": runtime],
                        proxyEngineLabels: ["conjet": expected]
                    )
                ).run(outputDirectory: outputDirectory.appendingPathComponent(runtime, isDirectory: true))
                allResults.append(contentsOf: engineResults)
            } catch {
                failures.append("\(canonical): \(error)")
                allResults.append(proxyEngineFailureResult(engine: canonical, error: error))
            }
            _ = try? runProcess(["/usr/bin/env", "swift", "run", "conjet", "network", "repair"], timeoutSeconds: 60)
            _ = try? runProcess(["/usr/bin/env", "swift", "run", "conjet", "stop", "--timeout", "10"], timeoutSeconds: 60)
        }
        _ = try? restartConjetForProxyEngine("auto", expectedStatus: expectedProxyEngineStatus("auto"))

        let allResultsURL = outputDirectory.appendingPathComponent("all-results.json")
        try ConjetJSON.string(allResults).write(to: allResultsURL, atomically: true, encoding: .utf8)
        let markdown = renderProxyEngineMarkdown(results: allResults, proxyEngines: proxyEngines, workloads: workloads, failures: failures)
        let report = outputDirectory.appendingPathComponent("network-proxy-engines.md")
        try markdown.write(to: report, atomically: true, encoding: .utf8)
        try markdown.write(to: outputDirectory.appendingPathComponent("REPORT.md"), atomically: true, encoding: .utf8)
        return BenchmarkSuiteOutcome(
            name: "network-proxy-engines",
            status: failures.isEmpty ? "measured" : "partial",
            durationSeconds: 0,
            outputDirectory: outputDirectory.path,
            reports: ["all-results": allResultsURL.path, "markdown": report.path, "report": outputDirectory.appendingPathComponent("REPORT.md").path],
            summary: failures.isEmpty ? "proxy engine comparison measured" : failures.joined(separator: "; ")
        )
    }

    private static func runBridgeEngineComparison(
        bridgeEngines: [String],
        samples: Int,
        workloads: [String],
        outputDirectory: URL,
        commandTimeout: Double
    ) throws -> BenchmarkSuiteOutcome {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var allResults: [BenchmarkResult] = []
        var failures: [String] = []
        let requestedEngines = bridgeEngines.map(normalizedBridgeEngineName)
        var activeBridge = "unknown"
        for engine in requestedEngines {
            do {
                activeBridge = try restartConjetForBridgeEngine(engine)
            } catch {
                failures.append("\(engine): \(error)")
                allResults.append(bridgeEngineFailureResult(engine: engine, activeBridge: activeBridge, error: error))
                continue
            }
            let engineResults = try NetworkBenchmarkSuite(
                options: NetworkBenchmarkOptions(
                    contexts: ["conjet"],
                    samples: samples,
                    commandTimeoutSeconds: commandTimeout,
                    workloads: workloads,
                    runtimeLabels: ["conjet": "conjet-\(engine)"],
                    proxyEngineLabels: ["conjet": "proxy-gcd-evented"]
                )
            ).run(outputDirectory: outputDirectory.appendingPathComponent("conjet-\(engine)", isDirectory: true))
            allResults.append(contentsOf: engineResults)
            _ = try? runProcess(["/usr/bin/env", "swift", "run", "conjet", "network", "repair"], timeoutSeconds: 60)
            _ = try? runProcess(["/usr/bin/env", "swift", "run", "conjet", "stop", "--timeout", "10"], timeoutSeconds: 60)
        }
        _ = try? restartConjetForBridgeEngine("conjet-netd-c")
        let allResultsURL = outputDirectory.appendingPathComponent("all-results.json")
        try ConjetJSON.string(allResults).write(to: allResultsURL, atomically: true, encoding: .utf8)
        let markdown = renderBridgeEngineMarkdown(results: allResults, bridgeEngines: requestedEngines, activeBridge: activeBridge, failures: failures)
        let report = outputDirectory.appendingPathComponent("network-bridge-engines.md")
        try markdown.write(to: report, atomically: true, encoding: .utf8)
        try markdown.write(to: outputDirectory.appendingPathComponent("REPORT.md"), atomically: true, encoding: .utf8)
        return BenchmarkSuiteOutcome(
            name: "network-bridge-engines",
            status: failures.isEmpty ? "measured" : "partial",
            durationSeconds: 0,
            outputDirectory: outputDirectory.path,
            reports: ["all-results": allResultsURL.path, "markdown": report.path, "report": outputDirectory.appendingPathComponent("REPORT.md").path],
            summary: failures.isEmpty ? "bridge engine comparison measured" : failures.joined(separator: "; ")
        )
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

    private static func benchmarkSamples() -> Int {
        5
    }

    private static func canonicalProxyEngine(_ value: String) -> String {
        switch value {
        case "gcd", "gcd-fallback":
            return "gcd-evented"
        case "event-loop", "proxy-nio":
            return "nio"
        default:
            return value
        }
    }

    private static func expectedProxyEngineStatus(_ engine: String) -> String {
        switch engine {
        case "gcd-evented":
            return "proxy-gcd-evented"
        case "nio":
            return "proxy-nio"
        case "auto":
            return "proxy-gcd-evented"
        default:
            return "proxy-\(engine)"
        }
    }

    private static func restartConjetForProxyEngine(_ engine: String, expectedStatus: String) throws {
        _ = try? runProcess(["/usr/bin/env", "swift", "run", "conjet", "stop", "--timeout", "10"], timeoutSeconds: 60)
        let start = try runProcess([
            "/usr/bin/env",
            "swift",
            "run",
            "conjet",
            "start",
            "--proxy-engine",
            engine
        ], timeoutSeconds: 120)
        guard start.succeeded else {
            throw ConjetError.unavailable("conjet start failed for proxy engine \(engine): \(start.stderr)")
        }
        let deadline = Date().addingTimeInterval(60)
        var lastStatus = ""
        while Date() < deadline {
            let status = try runProcess(["/usr/bin/env", "swift", "run", "conjet", "network", "status"], timeoutSeconds: 30)
            lastStatus = status.stdout + status.stderr
            if status.succeeded, lastStatus.contains("Proxy engine: \(expectedStatus)") {
                return
            }
            Thread.sleep(forTimeInterval: 1)
        }
        throw ConjetError.unavailable("timed out waiting for proxy engine \(expectedStatus); last status: \(lastStatus)")
    }

    @discardableResult
    private static func restartConjetForBridgeEngine(_ engine: String) throws -> String {
        let normalized = normalizedBridgeEngineName(engine)
        let switchResult = try runProcess([
            "/usr/bin/env",
            "swift",
            "run",
            "conjet",
            "network",
            "bridge-switch",
            normalized,
            "--restart"
        ], timeoutSeconds: 240)
        guard switchResult.succeeded else {
            throw ConjetError.unavailable("conjet bridge-switch failed for \(normalized): \(switchResult.stderr)")
        }

        let deadline = Date().addingTimeInterval(90)
        var lastStatus = ""
        while Date() < deadline {
            let status = try runProcess(["/usr/bin/env", "swift", "run", "conjet", "network", "status", "--json"], timeoutSeconds: 30)
            lastStatus = status.stdout + status.stderr
            let active = activeBridgeEngine(fromStatusJSON: status.stdout)
            if status.succeeded, active == normalized {
                return active
            }
            Thread.sleep(forTimeInterval: 1)
        }
        throw ConjetError.unavailable("timed out waiting for bridge engine \(normalized); last status: \(lastStatus)")
    }

    private static func proxyEngineFailureResult(engine: String, error: Error) -> BenchmarkResult {
        var metrics = BenchmarkMetrics()
        metrics.setString(expectedProxyEngineStatus(engine), for: "proxy_engine")
        metrics.setString("engine_restart_failed", for: "failure_reason")
        metrics.setString("pooled-vsock-prefetch", for: "bridge_engine")
        metrics.setString("python-threaded", for: "guest_bridge_engine")
        metrics.setString("legacy-tcp-proxy", for: "vsock_mode")
        metrics.setString("legacy-tcp-proxy", for: "tcp_mode")
        metrics.setString("legacy-udp-proxy", for: "udp_mode")
        metrics.setBool(false, for: "tcp_binary_frames")
        metrics.setBool(false, for: "persistent_tcp_vsock")
        metrics.setBool(false, for: "tcp_vsock_pool")
        metrics.setBool(true, for: "python_fallback_active")
        return BenchmarkResult(
            workload: "proxy-engine-start",
            runtime: "conjet-\(engine)",
            command: ["swift", "run", "conjet", "start"],
            startedAt: Date(),
            durationSeconds: 0,
            exitCode: 1,
            metrics: metrics,
            machine: MachineProfiler.capture(cacheTTLSeconds: 60),
            stderrTail: String(describing: error)
        )
    }

    private static func bridgeEngineFailureResult(engine: String, activeBridge: String, error: Error? = nil) -> BenchmarkResult {
        var metrics = BenchmarkMetrics()
        metrics.setString(engine, for: "bridge_engine")
        metrics.setString(activeBridge, for: "active_bridge_engine")
        metrics.setString("bridge_engine_unavailable", for: "failure_reason")
        metrics.setString("proxy-gcd-evented", for: "proxy_engine")
        metrics.setString("legacy-tcp-proxy", for: "vsock_mode")
        metrics.setString("legacy-tcp-proxy", for: "tcp_mode")
        metrics.setString("legacy-udp-proxy", for: "udp_mode")
        metrics.setBool(false, for: "tcp_binary_frames")
        metrics.setBool(false, for: "persistent_tcp_vsock")
        metrics.setBool(false, for: "tcp_vsock_pool")
        metrics.setBool(activeBridge == "python-legacy", for: "python_fallback_active")
        return BenchmarkResult(
            workload: "bridge-engine-start",
            runtime: "conjet-\(engine)",
            command: ["swift", "run", "conjet", "network", "status"],
            startedAt: Date(),
            durationSeconds: 0,
            exitCode: 1,
            metrics: metrics,
            machine: MachineProfiler.capture(cacheTTLSeconds: 60),
            stderrTail: error.map(String.init(describing:)) ?? "active guest bridge is \(activeBridge)"
        )
    }

    private static func normalizedBridgeEngineName(_ engine: String) -> String {
        switch engine {
        case "conjet-netd":
            return "conjet-netd-c"
        default:
            return engine
        }
    }

    private static func activeBridgeEngine(fromStatusJSON text: String) -> String {
        if let bridge = jsonStringField("bridgeEngine", in: text), !bridge.isEmpty {
            if bridge == "python-threaded" {
                return "python-legacy"
            }
            return bridge
        }
        if text.contains(#""tcpProxy""#) {
            return "python-legacy"
        }
        return "unknown"
    }

    private static func jsonStringField(_ field: String, in text: String) -> String? {
        guard let fieldRange = text.range(of: "\"\(field)\"") else { return nil }
        let suffix = text[fieldRange.upperBound...]
        guard let colon = suffix.firstIndex(of: ":") else { return nil }
        let afterColon = suffix[suffix.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard afterColon.first == "\"" else { return nil }
        let body = afterColon.dropFirst()
        guard let end = body.firstIndex(of: "\"") else { return nil }
        return String(body[..<end])
    }

    private static func jsonBoolField(_ field: String, in text: String) -> Bool? {
        guard let fieldRange = text.range(of: "\"\(field)\"") else { return nil }
        let suffix = text[fieldRange.upperBound...]
        guard let colon = suffix.firstIndex(of: ":") else { return nil }
        let afterColon = suffix[suffix.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        if afterColon.hasPrefix("true") { return true }
        if afterColon.hasPrefix("false") { return false }
        return nil
    }

    private static func ipv6UDPEcho(port: Int, payload: String) -> Bool {
        let fd = Darwin.socket(AF_INET6, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET6, "::1", &address.sin6_addr) == 1 else {
            return false
        }
        let bytes = [UInt8](payload.utf8)
        let sent = bytes.withUnsafeBytes { rawBuffer -> Int in
            guard let base = rawBuffer.baseAddress else { return -1 }
            return withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.sendto(fd, base, bytes.count, 0, socketAddress, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
        guard sent == bytes.count else { return false }
        var buffer = [UInt8](repeating: 0, count: 2048)
        let received = Darwin.recv(fd, &buffer, buffer.count, 0)
        guard received == bytes.count else { return false }
        return String(decoding: buffer.prefix(received), as: UTF8.self) == payload
    }

    private static func sshDisabledModeCheck(originalStatusJSON: String) throws -> Bool {
        let originallyEnabled = jsonBoolField("enabled", in: originalStatusJSON) != false
        defer {
            if originallyEnabled {
                _ = try? runProcess(["/usr/bin/env", "swift", "run", "conjet", "ssh", "enable", "--json"], timeoutSeconds: 120)
            } else {
                _ = try? runProcess(["/usr/bin/env", "swift", "run", "conjet", "ssh", "disable", "--json"], timeoutSeconds: 120)
            }
        }
        let disabled = try runProcess(["/usr/bin/env", "swift", "run", "conjet", "ssh", "disable", "--json"], timeoutSeconds: 120)
        guard disabled.succeeded,
              jsonStringField("message", in: disabled.stdout) == "profile SSH is disabled" else {
            return false
        }
        let attempt = try runProcess(["/usr/bin/env", "swift", "run", "conjet", "ssh", "true"], timeoutSeconds: 120)
        return !attempt.succeeded && attempt.stderr.contains("Conjet SSH is disabled")
    }

    private static func runProcess(_ command: [String], timeoutSeconds: Double?) throws -> ProcessResult {
        guard let executable = command.first else {
            throw ConjetError.invalidArgument("empty command")
        }
        return try ProcessRunner.run(executable, Array(command.dropFirst()), timeoutSeconds: timeoutSeconds)
    }

    private static func emitSingleGateResult(_ result: BenchmarkResult, args: [String]) throws {
        print(try ConjetJSON.string(result))
        if let output = value(after: "--output-dir", in: args) {
            let directory = URL(fileURLWithPath: expandedPath(output), isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(result.workload).json")
            try ConjetJSON.string(result).write(to: url, atomically: true, encoding: .utf8)
            print("  result: \(url.path)")
        }
    }

    private static func hostRSSMiB(processName: String) -> Double? {
        guard let pgrep = try? runProcess(["/usr/bin/pgrep", "-x", processName], timeoutSeconds: 5),
              pgrep.succeeded else {
            return nil
        }
        let pids = pgrep.stdout.split(whereSeparator: \.isNewline).map(String.init)
        guard !pids.isEmpty else { return nil }
        var totalKiB = 0.0
        for pid in pids {
            guard let ps = try? runProcess(["/bin/ps", "-o", "rss=", "-p", pid], timeoutSeconds: 5),
                  ps.succeeded,
                  let rss = Double(ps.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                continue
            }
            totalKiB += rss
        }
        return totalKiB / 1024.0
    }

    private static func guestRSSMetrics() throws -> BenchmarkMetrics {
        let output = try guestRootShell("""
        ps -eo comm=,rss= | awk '
        { rss[$1]+=$2 }
        END {
          for (name in rss) {
            print name " " rss[name]
          }
        }'
        """)
        guard output.succeeded else {
            throw ConjetError.processFailed(executable: "guest ps", exitCode: output.exitCode, stderr: output.stderr)
        }
        var metrics = BenchmarkMetrics()
        for line in output.stdout.split(whereSeparator: \.isNewline).map(String.init) {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let rssKiB = Double(parts[1]) else { continue }
            let rssMiB = rssKiB / 1024.0
            switch parts[0] {
            case "containerd":
                metrics["containerd_rss_mb"] = rssMiB
            case "dockerd":
                metrics["dockerd_rss_mb"] = rssMiB
            case "buildkitd":
                metrics["buildkitd_rss_mb"] = rssMiB
            case "sshd":
                metrics["sshd_rss_mb"] = rssMiB
            case "systemd":
                metrics["guest_agent_rss_mb"] = rssMiB
            default:
                continue
            }
        }
        return metrics
    }

    private static func measureFirstContainerSeconds() throws -> Double {
        let socket = ConjetPaths.default().dockerSocket.path
        let startedAt = Date()
        let result = try runProcess([
            "/usr/bin/env", "docker", "--host", "unix://\(socket)",
            "run", "--rm", "alpine:3.20", "true"
        ], timeoutSeconds: 120)
        guard result.succeeded else {
            throw ConjetError.processFailed(executable: "docker first container", exitCode: result.exitCode, stderr: result.stderr)
        }
        return Date().timeIntervalSince(startedAt)
    }

    private static func clockProbe() throws -> (hostEpochMs: Int, guestEpochMs: Int, deltaMs: Int) {
        let hostEpochMs = Int(Date().timeIntervalSince1970 * 1000)
        let result = try guestRootShell("date +%s%3N")
        guard result.succeeded else {
            throw ConjetError.processFailed(executable: "guest date", exitCode: result.exitCode, stderr: result.stderr)
        }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let guestEpochMs = Int(text) else {
            throw ConjetError.decoding("guest date returned unexpected value '\(text)'")
        }
        return (hostEpochMs, guestEpochMs, guestEpochMs - hostEpochMs)
    }

    private static func repairGuestClockForGate() throws -> Bool {
        let epochMs = Int(Date().timeIntervalSince1970 * 1000)
        let seconds = epochMs / 1000
        let milliseconds = epochMs % 1000
        let timestamp = "\(seconds).\(String(format: "%03d", milliseconds))"
        let result = try guestRootShell("""
        if command -v timedatectl >/dev/null 2>&1; then timedatectl set-ntp false >/dev/null 2>&1 || true; fi
        date -u -s @\(timestamp) >/dev/null 2>&1 || date -u -s @\(seconds) >/dev/null
        hwclock -w >/dev/null 2>&1 || true
        """)
        return result.succeeded
    }

    private static func guestRootShell(_ script: String) throws -> ProcessResult {
        let socket = ConjetPaths.default().dockerSocket.path
        guard FileManager.default.fileExists(atPath: socket) else {
            throw ConjetError.unavailable("Conjet Docker socket is not available; rerun with --start")
        }
        return try ProcessRunner.run("/usr/bin/env", [
            "docker",
            "--host",
            "unix://\(socket)",
            "run",
            "--rm",
            "--privileged",
            "--pid=host",
            "--net=host",
            "--ipc=host",
            "--uts=host",
            "ubuntu:24.04",
            "nsenter",
            "-t",
            "1",
            "-m",
            "-u",
            "-i",
            "-n",
            "-p",
            "--",
            "sh",
            "-lc",
            script
        ], timeoutSeconds: 120)
    }

    private static func samplePhase(_ value: String?) throws -> BenchmarkSamplePhase {
        guard let value else { return .any }
        guard let phase = BenchmarkSamplePhase(rawValue: value) else {
            throw ConjetError.invalidArgument("invalid phase '\(value)'")
        }
        return phase
    }

    private static func runAllSuiteSelection(_ value: String?) throws -> Set<String>? {
        guard let value else { return nil }
        let suites = csvList(value).map(canonicalRunAllSuiteName)
        guard !suites.isEmpty else {
            throw ConjetError.invalidArgument("--suites must contain at least one suite")
        }

        let validSuites = Set(runAllSuiteNames)
        let unknownSuites = suites.filter { !validSuites.contains($0) }
        guard unknownSuites.isEmpty else {
            throw ConjetError.invalidArgument(
                "unknown benchmark suites: \(unknownSuites.joined(separator: ", ")); valid suites: \(runAllSuiteNames.joined(separator: ", "))"
            )
        }
        return Set(suites)
    }

    private static func suiteIsSelected(_ suite: String, selectedSuites: Set<String>?) -> Bool {
        selectedSuites?.contains(suite) ?? true
    }

    private static var runAllSuiteNames: [String] {
        [
            "warm-gate",
            "cold-base-prepulled-gate",
            "no-cache-gate",
            "topology-gate",
            "polyglot-gate",
            "network-gate",
            "energy-gate"
        ]
    }

    private static func canonicalRunAllSuiteName(_ suite: String) -> String {
        switch suite {
        case "warm":
            return "warm-gate"
        case "cold-base-prepulled", "cold-prepulled":
            return "cold-base-prepulled-gate"
        case "no-cache":
            return "no-cache-gate"
        case "topology":
            return "topology-gate"
        case "polyglot":
            return "polyglot-gate"
        case "energy":
            return "energy-gate"
        case "network":
            return "network-gate"
        default:
            return suite
        }
    }

    private static func requiredBaselines(from contexts: [String]) -> [String] {
        let baselines = contexts.filter { $0 != "conjet" }
        return baselines.contains("orbstack") ? ["orbstack"] : baselines
    }

    private static func rulesRepresented(in results: [BenchmarkResult]) -> [BenchmarkClaimRule] {
        let workloads = Set(results.map(\.workload))
        let rules = BenchmarkClaimGateOptions.defaultRules.filter { rule in
            workloads.contains(rule.resolvedCandidateWorkload) ||
                workloads.contains(rule.resolvedBaselineWorkload)
        }
        return rules.isEmpty ? BenchmarkClaimGateOptions.defaultRules : rules
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

    private static func renderNetworkMarkdown(
        results: [BenchmarkResult],
        contexts: [String],
        workloads: [String]
    ) -> String {
        var lines = [
            "# ConjetNet Network Gate",
            "",
            "ConjetNet v2 is evaluated as secure localhost Docker TCP/UDP port publishing with visible diagnostics. This report is data, not a global superiority claim.",
            "",
            "- Contexts: \(contexts.joined(separator: ", "))",
            "- Workloads: \(workloads.joined(separator: ", "))",
            "- UDP failures mean UDP is unavailable, blocked, or not supported by the active guest/context.",
            "",
            "## Verdicts",
            "",
            "| Gate | Status | Evidence | Caveat |",
            "| --- | --- | --- | --- |"
        ]
        for row in networkVerdictRows(results: results, contexts: contexts) {
            lines.append("| \(row.name) | \(row.status) | \(row.evidence) | \(row.caveat) |")
        }
        lines += [
            "",
            "## Results",
            "",
            "| Workload | Runtime | Samples | Failures | P50 ms | P95 ms | P99 ms | Max ms | RPS | Helper CPU % | CPU/1k req | Throughput Mbps | Proxy Engine | Bridge Engine | TCP Mode | UDP Mode | TCP Pool | Python Fallback | Verdict |",
            "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- | --- | --- | --- | --- | --- |"
        ]
        let grouped = Dictionary(grouping: results) { "\($0.workload)|\($0.runtime)" }
        for key in grouped.keys.sorted() {
            guard let group = grouped[key], let first = group.first else { continue }
            let measured = group.filter(successfulMeasured)
            let p50Values = measured.map { networkTableMetric($0, preferred: "latency_p50_ms") }.sorted()
            let p95Values = measured.map { networkTableMetric($0, preferred: "latency_p95_ms") }.sorted()
            let p99Values = measured.map { networkTableMetric($0, preferred: "latency_p99_ms") }.sorted()
            let maxValues = measured.map { networkTableMetric($0, preferred: "max_latency_ms") }.sorted()
            let failures = group.filter { $0.exitCode != 0 }.count
            lines.append("| \(first.workload) | \(first.runtime) | \(group.count) | \(failures) | \(formatMS(percentile(p50Values, 0.50))) | \(formatMS(percentile(p95Values, 0.95))) | \(formatMS(percentile(p99Values, 0.99))) | \(formatMS(maxValues.last)) | \(formatGroupMetric(group, "requests_per_second")) | \(formatGroupMetric(group, "helper_cpu_percent_peak")) | \(formatGroupMetric(group, "cpu_per_1000_requests")) | \(formatGroupMetric(group, "throughput_mbps")) | \(metricString(first, "proxy_engine")) | \(metricString(first, "bridge_engine")) | \(metricString(first, "tcp_mode")) | \(metricString(first, "udp_mode")) | \(metricString(first, "tcp_vsock_pool")) | \(metricString(first, "python_fallback_active")) | \(networkRowVerdict(first: first, group: group, grouped: grouped)) |")
        }
        let failures = results.filter { $0.exitCode != 0 }
        if !failures.isEmpty {
            lines += [
                "",
                "## Failures",
                "",
                "| Workload | Runtime | Count | Reason |",
                "| --- | --- | ---: | --- |"
            ]
            let failureGroups = Dictionary(grouping: failures) { "\($0.workload)|\($0.runtime)|\(failureReason($0))" }
            for key in failureGroups.keys.sorted() {
                guard let group = failureGroups[key], let first = group.first else { continue }
                lines.append("| \(first.workload) | \(first.runtime) | \(group.count) | \(failureReason(first)) |")
            }
        }
        lines += [
            "",
            "## Claims",
            "",
            "- Proven: only workloads with zero failures and sufficient samples in this report.",
            "- Partial: ConjetNet functionality is measured when baseline workloads fail or candidate/baseline wins are mixed.",
            "- Not proven: Conjet beating OrbStack or Colima unless the measured rows show lower p50/p95/p99 for the configured workload.",
            "",
            "## Implementation Status",
            "",
            "- TCP publishing: measured by localhost HTTP workloads, including high-concurrency built-in clients when selected.",
            "- UDP publishing: measured by UDP echo workloads and payload-size variants when selected.",
            "- CPU/request: helper CPU sampling is reported when matching helper processes are visible; otherwise rows carry `helper_cpu_metrics_skipped_reason` in JSON.",
            "- Bind policy: secure-local is the default Conjet policy; docker-strict and lan-allowlist are CLI/profile-configurable.",
            "- Proxy engine: Conjet `auto` reports the host listener class; the active TCP transport is reported separately as `tcp_mode` and must be `persistent-binary-tcp-pool` for the native VSOCK pool path.",
            "- Native TCP evidence: rows expose `tcp_mode`, `tcp_vsock_pool`, and `python_fallback_active` so pooled native TCP cannot be confused with python fallback.",
            "- Throughput: iperf3 workloads are skipped by the built-in gate unless a future external iperf3 harness is enabled.",
            "- Turbo mode: scaffolded only, not a performance claim."
        ]
        return lines.joined(separator: "\n")
    }

    private static func renderProxyEngineMarkdown(
        results: [BenchmarkResult],
        proxyEngines: [String],
        workloads: [String],
        failures: [String]
    ) -> String {
        var lines = [
            "# Conjet Proxy Engine Network Gate",
            "",
            "This report compares Conjet proxy engines by restarting Conjet per engine and verifying `conjet network status` before sampling.",
            "",
            "- Proxy engines: \(proxyEngines.joined(separator: ", "))",
            "- Workloads: \(workloads.joined(separator: ", "))",
            "- Result labels are separate runtimes such as `conjet-gcd-evented` and `conjet-nio`; they are not mixed.",
            "",
            "## Results",
            "",
            "| Workload | Runtime | Samples | Failures | P50 ms | P95 ms | P99 ms | Max ms | RPS | Proxy Engine | Bridge Engine |",
            "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |"
        ]
        let grouped = Dictionary(grouping: results) { "\($0.workload)|\($0.runtime)" }
        for key in grouped.keys.sorted() {
            guard let group = grouped[key], let first = group.first else { continue }
            let values = group.filter(successfulMeasured).map { metricMilliseconds($0) }.sorted()
            let failures = group.filter { $0.exitCode != 0 }.count
            lines.append("| \(first.workload) | \(first.runtime) | \(group.count) | \(failures) | \(formatMS(percentile(values, 0.50))) | \(formatMS(percentile(values, 0.95))) | \(formatMS(percentile(values, 0.99))) | \(formatMS(values.last)) | \(formatGroupMetric(group, "requests_per_second")) | \(metricString(first, "proxy_engine")) | \(metricString(first, "bridge_engine")) |")
        }
        if !failures.isEmpty {
            lines += [
                "",
                "## Engine Failures",
                ""
            ]
            lines.append(contentsOf: failures.map { "- \($0)" })
        }
        lines += [
            "",
            "## Interpretation",
            "",
            "- Measured: only rows with zero failures and enough samples.",
            "- Partial: engine restart or workload failures are shown explicitly.",
            "- Not proven: NIO superiority unless NIO rows beat GCD rows on the selected p50/p95/p99 metrics."
        ]
        return lines.joined(separator: "\n")
    }

    private static func renderBridgeEngineMarkdown(
        results: [BenchmarkResult],
        bridgeEngines: [String],
        activeBridge: String,
        failures: [String]
    ) -> String {
        var lines = [
            "# Conjet Bridge Engine Network Gate",
            "",
            "This report compares guest bridge engines when the requested bridge is active. It does not relabel Python results as conjet-netd results.",
            "",
            "- Requested bridge engines: \(bridgeEngines.joined(separator: ", "))",
            "- Active bridge engine: \(activeBridge)",
            "",
            "## Results",
            "",
            "| Workload | Runtime | Samples | Failures | P50 ms | P95 ms | P99 ms | Max ms | RPS | Helper CPU % | Bridge Engine | UDP Frame |",
            "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |"
        ]
        let grouped = Dictionary(grouping: results) { "\($0.workload)|\($0.runtime)" }
        for key in grouped.keys.sorted() {
            guard let group = grouped[key], let first = group.first else { continue }
            let values = group.filter(successfulMeasured).map { metricMilliseconds($0) }.sorted()
            let failures = group.filter { $0.exitCode != 0 }.count
            lines.append("| \(first.workload) | \(first.runtime) | \(group.count) | \(failures) | \(formatMS(percentile(values, 0.50))) | \(formatMS(percentile(values, 0.95))) | \(formatMS(percentile(values, 0.99))) | \(formatMS(values.last)) | \(formatGroupMetric(group, "requests_per_second")) | \(formatGroupMetric(group, "helper_cpu_percent_peak")) | \(metricString(first, "bridge_engine")) | \(metricString(first, "udp_frame_format")) |")
        }
        if !failures.isEmpty {
            lines += ["", "## Bridge Engine Failures", ""]
            lines.append(contentsOf: failures.map { "- \($0)" })
        }
        lines += [
            "",
            "## Interpretation",
            "",
            "- Measured: requested bridge engine was active and sampled.",
            "- Partial: one or more requested bridge engines were unavailable.",
            "- Not proven: conjet-netd performance unless rows show `bridge_engine=conjet-netd-c` or equivalent."
        ]
        return lines.joined(separator: "\n")
    }

    private static func renderNetworkSegmentsMarkdown(
        results: [BenchmarkResult],
        contexts: [String],
        workloads: [String]
    ) -> String {
        var lines = [
            "# ConjetNet Segment Benchmarks",
            "",
            "These microbenchmarks separate local loopback overhead from the full published-port path where the current guest image permits measurement.",
            "",
            "- Contexts: \(contexts.joined(separator: ", "))",
            "- Workloads: \(workloads.joined(separator: ", "))",
            "",
            "## Current Data Path",
            "",
            "macOS listener -> proxy-nio/proxy-gcd-evented -> VSOCK adapter -> active guest bridge reported per row -> container",
            "",
            "## Suspected Bottlenecks",
            "",
            "- Per-connection VSOCK setup remains in the TCP fast path unless the pooled connector has idle connections.",
            "- UDP uses a persistent binary guest session when `persistent_vsock=true`, but the full UDP path can still spend time in host session routing, guest UDP socket/NAT handling, and Docker's UDP publish path.",
            "- The active bridge is reported per row. Python fallback remains available, while conjet-netd-c must be proven by `bridge_engine=conjet-netd-c` rows.",
            "- Internal host-to-VSOCK echo and guest-bridge echo use `/conjet-guest-echo` when the active guest bridge exposes it; unavailable segments are reported, not hidden.",
            "",
            "## Results",
            "",
            "| Workload | Runtime | Samples | Failures | P50 ms | P95 ms | P99 ms | Max ms | Segment | Proxy Engine | Bridge Engine | Guest Bridge | Reason |",
            "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- | --- | --- | --- |"
        ]
        let grouped = Dictionary(grouping: results) { "\($0.workload)|\($0.runtime)" }
        for key in grouped.keys.sorted() {
            guard let group = grouped[key], let first = group.first else { continue }
            let values = group.filter(successfulMeasured).map { metricMilliseconds($0) }.sorted()
            let failures = group.filter { $0.exitCode != 0 }.count
            lines.append("| \(first.workload) | \(first.runtime) | \(group.count) | \(failures) | \(formatMS(percentile(values, 0.50))) | \(formatMS(percentile(values, 0.95))) | \(formatMS(percentile(values, 0.99))) | \(formatMS(values.last)) | \(metricString(first, "segment")) | \(metricString(first, "proxy_engine")) | \(metricString(first, "bridge_engine")) | \(metricString(first, "guest_bridge_engine")) | \(failureReason(first)) |")
        }
        lines += [
            "",
            "## Claims",
            "",
            "- Proven: segment rows with measured latency and zero failures.",
            "- Not proven: muxed VSOCK or PF/vmnet turbo latency; those paths are not implemented.",
            "- Current bridge mode is reported per row through `bridge_engine`, `guest_bridge_engine`, `tcp_mode`, `udp_mode`, `vsock_mode`, `udp_frame_format`, and `python_fallback_active`."
        ]
        return lines.joined(separator: "\n")
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
              conjet-bench memory-gate [--start] [--first-container] [--output-dir DIR]
              conjet-bench clock-gate [--start] [--repair] [--output-dir DIR]
              conjet-bench ssh-gate [--start] [--require-endpoint] [--output-dir DIR]
              conjet-bench ipv6-gate [--start] [--output-dir DIR]
              conjet-bench network-gate [options]
              conjet-bench network-segments [options]
              conjet-bench gate --reports PATH[,PATH...]

            Commands:
              run          Run energy in isolation, then wall-time suites in parallel.
              energy-gate  Run only the powermetrics energy gate.
              memory-gate  Measure Conjet memory profile policy plus host/guest RSS.
              clock-gate   Measure and optionally repair host/guest clock drift.
              ssh-gate     Verify profile key, guest sshd hardening, and optional endpoint.
              ipv6-gate    Verify scoped ::1 TCP publication.
              network-gate Run ConjetNet localhost TCP/UDP network gate.
              network-segments
                          Run ConjetNet path-segmentation microbenchmarks.
              gate         Score existing raw JSON reports.
              help         Show this help text.

            Run options:
              --contexts LIST          Docker contexts to measure (default: conjet,orbstack,colima)
              --samples N              Accepted for compatibility; benchmark runs use 5 samples
              --suites LIST            Run only selected suites: warm-gate,cold-base-prepulled-gate,no-cache-gate,topology-gate,polyglot-gate,network-gate,energy-gate
              --network-workloads LIST Network workloads for run-all network-gate
              --skip-udp              Omit UDP workloads from network-gate
              --require-udp           Reserved for strict UDP gating; baseline UDP failures are still reported
              --proxy-engines LIST    Restart Conjet per engine and compare: gcd-evented,nio
              --bridge-engines LIST   Compare active guest bridge engines: python-legacy,conjet-netd-c
              --allow-baseline-failures
                                      Keep full gate partial when baselines fail instead of failing Conjet functional gate
              --require-iperf3        Reserved for future external iperf3 throughput gating
              --polyglot-samples N     Accepted for compatibility; benchmark runs use 5 samples
              --ecosystems LIST        js,python,jvm,dotnet,go,rust,cpp
              --output-dir DIR         Report root (default: benchmarks/reports/run-all-YYYYMMDD-HHMMSS)
              --command-timeout N      Docker workload timeout in seconds (default: 240)
              --energy-samples N       Accepted for compatibility; benchmark runs use 5 samples
              --energy-seconds N       Idle energy sample duration (default: 10)
              --keep-work              Keep generated workload directories for debugging
              --require-power          Fail energy suite if powermetrics cannot measure
              --no-energy              Skip energy gate
              --no-polyglot            Skip polyglot gate
              --no-network             Skip network gate
              --no-cache-suite         Skip no-cache gate
              --required-baselines LIST Hard-fail gate baselines for existing-report scoring

            Notes:
              Only energy-gate executes sudo -v because powermetrics requires privilege.
              Wall-time suites, including network-gate, do not require a sudo timestamp.
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

    private static func metricMilliseconds(_ result: BenchmarkResult) -> Double {
        if let value = result.metrics["latency_p50_ms"] {
            return value
        }
        if let value = result.metrics["port_publication_latency_ms"] {
            return value
        }
        return result.durationSeconds * 1_000
    }

    private static func networkTableMetric(_ result: BenchmarkResult, preferred key: String) -> Double {
        if let value = result.metrics[key] {
            return value
        }
        if let value = result.metrics["port_publication_latency_ms"] {
            return value
        }
        if let value = result.metrics["latency_p50_ms"] {
            return value
        }
        return result.durationSeconds * 1_000
    }

    private static func successfulMeasured(_ result: BenchmarkResult) -> Bool {
        result.exitCode == 0 && result.metrics.value(for: "skipped") != .bool(true)
    }

    private struct NetworkSuiteStatus {
        var status: String
        var summary: String
    }

    private struct NetworkVerdictRow {
        var name: String
        var status: String
        var evidence: String
        var caveat: String
    }

    private static func networkSuiteStatus(_ results: [BenchmarkResult]) -> NetworkSuiteStatus {
        let conjet = results.filter { $0.runtime == "conjet" }
        guard !conjet.isEmpty else {
            return NetworkSuiteStatus(status: "failed", summary: "Conjet network samples were not collected")
        }
        let conjetFailures = conjet.filter { $0.exitCode != 0 }.count
        if conjetFailures > 0 {
            return NetworkSuiteStatus(status: "failed", summary: "\(conjetFailures) Conjet network samples failed")
        }
        let baselineFailures = results.filter { $0.runtime != "conjet" && $0.exitCode != 0 }.count
        if baselineFailures > 0 {
            return NetworkSuiteStatus(status: "partial", summary: "Conjet passed; \(baselineFailures) baseline network samples failed")
        }
        return NetworkSuiteStatus(status: "measured", summary: "network results measured")
    }

    private static func networkVerdictRows(results: [BenchmarkResult], contexts: [String]) -> [NetworkVerdictRow] {
        let conjet = results.filter { $0.runtime == "conjet" }
        let conjetFailures = conjet.filter { $0.exitCode != 0 }.count
        let conjetStatus = conjet.isEmpty ? "Not measured" : (conjetFailures == 0 ? "Pass" : "Failed")
        var rows = [
            NetworkVerdictRow(
                name: "Conjet functional gate",
                status: conjetStatus,
                evidence: conjet.isEmpty ? "No Conjet samples" : "\(conjet.count) Conjet samples, \(conjetFailures) failures",
                caveat: "Functional pass does not imply baseline superiority"
            )
        ]
        for baseline in contexts where baseline != "conjet" {
            let comparison = comparisonVerdict(results: results, baseline: baseline)
            rows.append(NetworkVerdictRow(
                name: "Conjet vs \(baseline)",
                status: comparison.status,
                evidence: comparison.evidence,
                caveat: comparison.caveat
            ))
        }
        let failures = results.filter { $0.exitCode != 0 }.count
        rows.append(NetworkVerdictRow(
            name: "Full multi-runtime gate",
            status: failures == 0 ? "Pass" : (conjetFailures == 0 ? "Partial" : "Failed"),
            evidence: "\(results.count) samples, \(failures) failures",
            caveat: failures == 0 ? "All configured runtime rows completed" : "Baseline failures do not mark Conjet functional gate failed"
        ))
        return rows
    }

    private static func comparisonVerdict(results: [BenchmarkResult], baseline: String) -> (status: String, evidence: String, caveat: String) {
        let workloads = Set(results.map(\.workload))
        var candidateWins = 0
        var baselineWins = 0
        var unavailable = 0
        var candidateFailed = 0
        var baselineFailed = 0

        for workload in workloads.sorted() {
            let candidateRows = results.filter { $0.runtime == "conjet" && $0.workload == workload }
            let baselineRows = results.filter { $0.runtime == baseline && $0.workload == workload }
            guard !candidateRows.isEmpty, !baselineRows.isEmpty else {
                unavailable += 1
                continue
            }
            if candidateRows.contains(where: { $0.exitCode != 0 }) {
                candidateFailed += 1
                continue
            }
            if baselineRows.contains(where: { $0.exitCode != 0 }) {
                baselineFailed += 1
                continue
            }
            let candidateP95 = percentile(candidateRows.map(metricMilliseconds).sorted(), 0.95) ?? .greatestFiniteMagnitude
            let baselineP95 = percentile(baselineRows.map(metricMilliseconds).sorted(), 0.95) ?? .greatestFiniteMagnitude
            if candidateP95 <= baselineP95 {
                candidateWins += 1
            } else {
                baselineWins += 1
            }
        }

        if candidateFailed > 0 {
            return ("Failed", "\(candidateFailed) candidate workload groups failed", "Fix Conjet failures before comparing against \(baseline)")
        }
        if candidateWins > 0, baselineWins == 0, baselineFailed == 0, unavailable == 0 {
            return ("Pass", "Conjet won \(candidateWins) comparable workload groups by p95", "Local benchmark only")
        }
        if candidateWins == 0, baselineWins > 0, baselineFailed == 0 {
            return ("Failed", "\(baseline) won \(baselineWins) comparable workload groups by p95", "No Conjet wins in comparable groups")
        }
        return (
            "Partial",
            "Conjet wins: \(candidateWins); \(baseline) wins: \(baselineWins); baseline failed: \(baselineFailed); unavailable: \(unavailable)",
            "Mixed results or baseline failures prevent a broad superiority claim"
        )
    }

    private static func networkRowVerdict(
        first: BenchmarkResult,
        group: [BenchmarkResult],
        grouped: [String: [BenchmarkResult]]
    ) -> String {
        let failures = group.filter { $0.exitCode != 0 }.count
        if failures > 0 {
            return first.runtime == "conjet" ? "candidate_failed" : "baseline_failed"
        }
        guard first.runtime != "conjet" else { return "candidate_measured" }
        guard let candidate = grouped["\(first.workload)|conjet"],
              candidate.allSatisfy({ $0.exitCode == 0 }) else {
            return "comparison_unavailable"
        }
        let candidateP95 = percentile(candidate.map(metricMilliseconds).sorted(), 0.95) ?? .greatestFiniteMagnitude
        let baselineP95 = percentile(group.map(metricMilliseconds).sorted(), 0.95) ?? .greatestFiniteMagnitude
        return candidateP95 <= baselineP95 ? "candidate_wins" : "baseline_wins"
    }

    private static func metricString(_ result: BenchmarkResult, _ key: String) -> String {
        result.metrics.value(for: key)?.summaryValue ?? "null"
    }

    private static func formatMetric(_ result: BenchmarkResult, _ key: String) -> String {
        guard let value = result.metrics[key] else { return "null" }
        return String(format: "%.3f", value)
    }

    private static func formatGroupMetric(_ group: [BenchmarkResult], _ key: String) -> String {
        let values = group.compactMap { $0.metrics[key] }.sorted()
        guard let value = percentile(values, 0.50) else { return "null" }
        return String(format: "%.3f", value)
    }

    private static func failureReason(_ result: BenchmarkResult) -> String {
        if case .string(let reason)? = result.metrics.value(for: "failure_reason") {
            return reason
        }
        let stderr = result.stderrTail
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return stderr ?? "unknown"
    }

    private static func percentile(_ values: [Double], _ quantile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let index = min(values.count - 1, max(0, Int((Double(values.count) * quantile).rounded(.down))))
        return values[index]
    }

    private static func formatMS(_ value: Double?) -> String {
        guard let value else { return "null" }
        return String(format: "%.3f", value)
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

    private static func benchmarkResourceScope(outputDirectory: URL, now: Date = Date()) -> String {
        let milliseconds = Int((now.timeIntervalSince1970 * 1_000).rounded())
        return "\(outputDirectory.lastPathComponent)-\(milliseconds)"
    }

    private static func cleanupBenchmarkDumps(in directory: URL) {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return
        }

        var dumpDirectories: [URL] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "work" else {
                continue
            }
            dumpDirectories.append(url)
            enumerator.skipDescendants()
        }

        for dumpDirectory in dumpDirectories {
            try? fileManager.removeItem(at: dumpDirectory)
        }
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

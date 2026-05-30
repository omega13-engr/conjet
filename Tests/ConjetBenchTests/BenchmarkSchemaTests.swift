import ConjetBench
import ConjetCore
import XCTest

final class BenchmarkSchemaTests: XCTestCase {
    func testSmallFileWorkloadProducesSchema() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try SmallFileWorkload(fileCount: 4, bytesPerFile: 16).run(directory: directory)
        XCTAssertEqual(result.workload, "many-small-files")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.metrics["file_count"], 4)
        XCTAssertEqual(result.metrics["total_bytes"], 64)
    }

    func testMarkdownReportContainsBenchmarkTable() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try SmallFileWorkload(fileCount: 2, bytesPerFile: 8).run(directory: directory)
        let markdown = BenchmarkMarkdownReport.render(results: [result])
        XCTAssertTrue(markdown.contains("# Conjet Benchmark Report"))
        XCTAssertTrue(markdown.contains("| Workload | Runtime | Samples | Failures | P50 (s) | P95 (s) | Mean (s) | StdDev (s) |"))
        XCTAssertTrue(markdown.contains("| Workload | Runtime | Duration (s) | Exit | Key Metrics |"))
        XCTAssertTrue(markdown.contains("file_count=2"))
    }

    func testMarkdownReportIncludesFailureDetails() throws {
        let machine = MachineProfiler.capture()
        let result = BenchmarkResult(
            workload: "bind-npm-install",
            runtime: "conjet",
            command: ["docker", "run", "node:22-alpine"],
            startedAt: Date(),
            durationSeconds: 0.1,
            exitCode: 125,
            machine: machine,
            stdoutTail: "",
            stderrTail: "mount source path does not exist"
        )

        let markdown = BenchmarkMarkdownReport.render(results: [result])

        XCTAssertTrue(markdown.contains("## Failures"))
        XCTAssertTrue(markdown.contains("bind-npm-install / conjet"))
        XCTAssertTrue(markdown.contains("mount source path does not exist"))
    }

    func testDockerBenchmarkSuiteBuildsRepeatableContextCommands() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-docker-bench-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = DockerCommandRecorder()
        let suite = DockerBenchmarkSuite(
            contexts: ["conjet"],
            iterations: 2,
            warmup: true,
            runner: recorder.run,
            inputRunner: recorder.runWithInput
        )
        let results = try suite.run(workDirectory: directory)

        XCTAssertEqual(results.count, DockerBenchmarkSuite.defaultWorkloads.count * 2)
        XCTAssertEqual(Set(results.map(\.workload)), Set(DockerBenchmarkSuite.defaultWorkloads))
        XCTAssertTrue(recorder.commands.contains(["docker", "--context", "conjet", "pull", "alpine:3.20"]))
        XCTAssertTrue(recorder.commands.contains(["docker", "--context", "conjet", "pull", "busybox:1.36"]))
        XCTAssertTrue(recorder.commands.contains(["docker", "--context", "conjet", "pull", "node:22-alpine"]))
        XCTAssertTrue(recorder.commands.contains(["docker", "--context", "conjet", "pull", "rust:1-alpine"]))
        XCTAssertTrue(recorder.commands.contains { command in
            command.starts(with: ["docker", "--context", "conjet", "build"]) &&
                command.contains("CONJET_BENCH_ITERATION=1")
        })
        XCTAssertTrue(recorder.commands.contains { command in
            command.contains("type=volume,source=conjet-bench-conjet-volume-1,target=/data")
        })
        XCTAssertTrue(recorder.commands.contains { command in
            command.contains(where: { $0.contains("type=bind") && $0.contains("bind-npm-install") })
        })
        XCTAssertTrue(recorder.commands.contains { command in
            command.contains("type=volume,source=conjet-bench-conjet-npm-volume-1,target=/app")
        })
        XCTAssertTrue(recorder.commands.contains { command in
            command.contains(where: { $0.contains("type=bind") && $0.contains("bind-cargo-build") })
        })
        XCTAssertTrue(recorder.commands.contains { command in
            command.contains("type=volume,source=conjet-bench-conjet-cargo-volume-1,target=/app")
        })
        XCTAssertTrue(recorder.commands.contains { command in
            command.contains("--tmpfs") && command.contains("/scratch:rw,size=64m")
        })
        XCTAssertTrue(recorder.commands.contains { command in
            command.contains(where: { $0.contains("type=bind") && $0.contains("bind-hot-reload") })
        })
        XCTAssertTrue(recorder.commands.contains { command in
            command.contains(where: { $0.contains("bind-hot-reload") }) &&
                command.contains("node:22-alpine") &&
                command.contains(where: { $0.contains("fs.watch") })
        })
        XCTAssertTrue(recorder.commands.contains { command in
            command.joined(separator: " ").contains("hot-reload-detected")
        })
        XCTAssertTrue(recorder.commands.contains { command in
            command.starts(with: ["docker", "--context", "conjet", "wait"])
        })
        XCTAssertTrue(recorder.commands.contains { command in
            command.joined(separator: " ").contains("NPM_CONFIG_STORE_DIR='/app/.pnpm-store'")
        })
        XCTAssertTrue(recorder.commands.contains { command in
            command.joined(separator: " ").contains("NPM_CONFIG_STORE_DIR='/workspace/.pnpm-store'")
        })
        let conjetFSHotReloadResults = results.filter { $0.workload == "conjetfs-hot-reload" }
        XCTAssertEqual(conjetFSHotReloadResults.count, 2)
        XCTAssertTrue(conjetFSHotReloadResults.allSatisfy { $0.metrics["hot_reload_seconds"] != nil })
        XCTAssertTrue(conjetFSHotReloadResults.allSatisfy { $0.metrics["watch_sync_seconds"] != nil })
        XCTAssertTrue(conjetFSHotReloadResults.allSatisfy { $0.metrics["watch_event_paths"] != nil })
        XCTAssertTrue(results.allSatisfy { $0.metrics[BenchmarkSamplePhase.metricKey] == BenchmarkSamplePhase.warm.metricValue })
        XCTAssertTrue(results.allSatisfy { $0.metrics["benchmark_warmup"] == 1 })
        XCTAssertTrue(results.allSatisfy { $0.runtime == "conjet" })
        XCTAssertTrue(results.allSatisfy { !$0.command.isEmpty })
    }

    func testConjetFSPackageCachesAreOnlyMountedForWarmRuns() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-docker-bench-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let coldRecorder = DockerCommandRecorder()
        let coldResults = try DockerBenchmarkSuite(
            contexts: ["conjet"],
            iterations: 1,
            warmup: false,
            workloads: ["conjetfs-pnpm-install"],
            runner: coldRecorder.run,
            inputRunner: coldRecorder.runWithInput
        ).run(workDirectory: directory.appendingPathComponent("cold", isDirectory: true))

        XCTAssertEqual(coldResults.count, 1)
        XCTAssertEqual(coldResults.first?.metrics[BenchmarkSamplePhase.metricKey], BenchmarkSamplePhase.cold.metricValue)
        XCTAssertEqual(coldResults.first?.metrics["package_cache_mounts"], 0)
        XCTAssertFalse(coldResults.first?.command.joined(separator: " ").contains("conjet-package-corepack-cache") ?? true)
        XCTAssertFalse(coldResults.first?.command.joined(separator: " ").contains("conjet-package-npm-cache") ?? true)

        let warmRecorder = DockerCommandRecorder()
        let warmResults = try DockerBenchmarkSuite(
            contexts: ["conjet"],
            iterations: 1,
            warmup: true,
            workloads: ["conjetfs-pnpm-install"],
            runner: warmRecorder.run,
            inputRunner: warmRecorder.runWithInput
        ).run(workDirectory: directory.appendingPathComponent("warm", isDirectory: true))

        XCTAssertEqual(warmResults.count, 1)
        XCTAssertEqual(warmResults.first?.metrics[BenchmarkSamplePhase.metricKey], BenchmarkSamplePhase.warm.metricValue)
        XCTAssertEqual(warmResults.first?.metrics["package_cache_mounts"], 2)
        XCTAssertTrue(warmResults.first?.command.joined(separator: " ").contains("conjet-package-corepack-cache") ?? false)
        XCTAssertTrue(warmResults.first?.command.joined(separator: " ").contains("conjet-package-npm-cache") ?? false)
    }

    func testBindPackageWarmupPrefillsStoresBeforeMeasuredRuns() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-docker-bench-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let coldRecorder = DockerCommandRecorder()
        _ = try DockerBenchmarkSuite(
            contexts: ["orbstack"],
            iterations: 1,
            warmup: false,
            workloads: ["bind-pnpm-install"],
            runner: coldRecorder.run,
            inputRunner: coldRecorder.runWithInput
        ).run(workDirectory: directory.appendingPathComponent("cold", isDirectory: true))
        let coldBindRuns = coldRecorder.commands.filter { command in
            command.joined(separator: " ").contains("bind-pnpm-install") &&
                command.contains("run")
        }
        XCTAssertEqual(coldBindRuns.count, 1)

        let warmRecorder = DockerCommandRecorder()
        let warmResults = try DockerBenchmarkSuite(
            contexts: ["orbstack"],
            iterations: 1,
            warmup: true,
            workloads: ["bind-pnpm-install"],
            runner: warmRecorder.run,
            inputRunner: warmRecorder.runWithInput
        ).run(workDirectory: directory.appendingPathComponent("warm", isDirectory: true))
        let warmBindRuns = warmRecorder.commands.filter { command in
            command.joined(separator: " ").contains("bind-pnpm-install") &&
                command.contains("run")
        }

        XCTAssertEqual(warmResults.count, 1)
        XCTAssertEqual(warmBindRuns.count, 2)
        XCTAssertTrue(warmBindRuns.allSatisfy { $0.joined(separator: " ").contains("NPM_CONFIG_STORE_DIR='/app/.pnpm-store'") })
        XCTAssertEqual(warmResults.first?.metrics[BenchmarkSamplePhase.metricKey], BenchmarkSamplePhase.warm.metricValue)
    }

    func testBenchmarkClaimGateDefaultsUseHotReloadLatencyMetric() throws {
        let hotReloadRules = BenchmarkClaimGateOptions.defaultRules
            .filter { $0.workload == "bind-hot-reload" || $0.workload == "conjetfs-hot-reload" || $0.workload == "hot-reload-fast-path" }

        XCTAssertEqual(hotReloadRules.count, 2)
        XCTAssertTrue(hotReloadRules.allSatisfy { $0.measure == .metric("hot_reload_seconds") })
        XCTAssertNil(hotReloadRules.first { $0.workload == "conjetfs-hot-reload" })
        let fastPath = try XCTUnwrap(hotReloadRules.first { $0.workload == "hot-reload-fast-path" })
        XCTAssertEqual(fastPath.resolvedCandidateWorkload, "conjetfs-hot-reload")
        XCTAssertEqual(fastPath.resolvedBaselineWorkload, "bind-hot-reload")
    }

    func testDockerBenchmarkSuiteCanSelectWorkloads() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-docker-bench-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = DockerCommandRecorder()
        let suite = DockerBenchmarkSuite(
            contexts: ["conjet"],
            iterations: 1,
            warmup: false,
            workloads: ["npm-install"],
            runner: recorder.run,
            inputRunner: recorder.runWithInput
        )
        let results = try suite.run(workDirectory: directory)

        XCTAssertEqual(results.map(\.workload), ["npm-install"])
        XCTAssertEqual(results.first?.metrics["dependency_count"], 3)
        XCTAssertTrue(recorder.commands.contains { command in
            command.starts(with: ["docker", "--context", "conjet", "build"]) &&
                command.contains("--no-cache")
        })
        XCTAssertTrue(recorder.commands.allSatisfy { command in
            command.starts(with: ["docker", "--context", "conjet", "pull"]) ||
            command.starts(with: ["docker", "--context", "conjet", "build"]) ||
                command.starts(with: ["docker", "--context", "conjet", "rmi"])
        })
    }

    func testIdleResourceSamplerAggregatesMatchingProcesses() throws {
        var calls = 0
        let sampler = IdleResourceSampler(
            runtime: "conjet",
            processPattern: "conjetd",
            durationSeconds: 1,
            intervalSeconds: 0.1
        ) { executable, arguments in
            calls += 1
            return ProcessResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                stdout: """
                   100   0.5   0.2 /Users/sly/conjetd --serve
                   101   1.5   0.4 /Users/sly/conjetd helper
                   102  20.0   2.0 /Applications/Other.app/Contents/MacOS/Other
                """,
                stderr: ""
            )
        }

        let result = try sampler.run()

        XCTAssertEqual(result.workload, "idle-resource-sample")
        XCTAssertEqual(result.runtime, "conjet")
        XCTAssertGreaterThanOrEqual(calls, 1)
        XCTAssertEqual(result.metrics["process_count_mean"], 2)
        XCTAssertEqual(result.metrics["cpu_percent_mean"], 2.0)
        XCTAssertEqual(result.metrics["memory_percent_mean"] ?? 0, 0.6, accuracy: 0.0001)
    }

    func testPowerMetricsSamplerParsesPowerAndMatchedProcessEnergy() throws {
        let sampler = PowerMetricsSampler(
            runtime: "conjet",
            processPattern: "conjetd",
            durationSeconds: 2,
            intervalSeconds: 1,
            useSudo: false
        ) { executable, arguments in
            ProcessResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                stdout: """
                **** Sampled system activity ****
                CPU Power: 120 mW
                GPU Power: 30 mW
                ANE Power: 5 mW
                Combined Power (CPU + GPU + ANE): 155 mW
                conjetd 120 energy impact: 0.25 wakeups/sec: 4 idle wakeups/sec: 2
                launchd 1 energy impact: 4.0 wakeups/sec: 100
                **** Sampled system activity ****
                CPU Power: 80 mW
                GPU Power: 10 mW
                ANE Power: 1 mW
                Combined Power (CPU + GPU + ANE): 91 mW
                conjetd 120 energy impact: 0.75 wakeups/sec: 2 idle wakeups/sec: 1
                """,
                stderr: ""
            )
        }

        let result = try sampler.run()

        XCTAssertEqual(result.workload, "idle-power-sample")
        XCTAssertEqual(result.runtime, "conjet")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.command.first, "/usr/bin/powermetrics")
        XCTAssertEqual(result.metrics["requested_sample_count"], 2)
        XCTAssertEqual(result.metrics["powermetrics_sample_count"], 2)
        XCTAssertEqual(result.metrics["matched_process_lines"], 2)
        XCTAssertEqual(result.metrics["cpu_power_mw_mean"] ?? 0, 100, accuracy: 0.0001)
        XCTAssertEqual(result.metrics["combined_power_mw_mean"] ?? 0, 123, accuracy: 0.0001)
        XCTAssertEqual(result.metrics["matched_energy_impact_mean"] ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(result.metrics["matched_wakeups_per_second_mean"] ?? 0, 3, accuracy: 0.0001)
        XCTAssertEqual(result.metrics["matched_idle_wakeups_per_second_mean"] ?? 0, 1.5, accuracy: 0.0001)
    }

    func testPowerMetricsSamplerRecordsPermissionFailureAsBenchmarkFailure() throws {
        let sampler = PowerMetricsSampler(
            runtime: "orbstack",
            processPattern: "orbstack",
            durationSeconds: 1,
            intervalSeconds: 1,
            useSudo: true
        ) { executable, arguments in
            ProcessResult(
                executable: executable,
                arguments: arguments,
                exitCode: 1,
                stdout: "",
                stderr: "sudo: a password is required\n"
            )
        }

        let result = try sampler.run()

        XCTAssertEqual(result.workload, "idle-power-sample")
        XCTAssertEqual(result.runtime, "orbstack")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.command.prefix(3), ["/usr/bin/sudo", "-n", "/usr/bin/powermetrics"])
        XCTAssertTrue(result.stderrTail.contains("password is required"))
    }

    func testBenchmarkClaimGatePassesWhenCandidateBeatsAllBaselines() throws {
        let rules = [
            BenchmarkClaimRule(workload: "copy-node-modules"),
            BenchmarkClaimRule(workload: "idle-resource-sample", measure: .metric("cpu_percent_mean"))
        ]
        let results =
            makeResults(workload: "copy-node-modules", runtime: "conjet", values: [0.8, 0.9, 1.0]) +
            makeResults(workload: "copy-node-modules", runtime: "orbstack", values: [1.2, 1.3, 1.4]) +
            makeResults(workload: "copy-node-modules", runtime: "colima", values: [1.4, 1.5, 1.6]) +
            makeResults(workload: "idle-resource-sample", runtime: "conjet", metric: "cpu_percent_mean", values: [0.1, 0.2, 0.3]) +
            makeResults(workload: "idle-resource-sample", runtime: "orbstack", metric: "cpu_percent_mean", values: [0.3, 0.4, 0.5]) +
            makeResults(workload: "idle-resource-sample", runtime: "colima", metric: "cpu_percent_mean", values: [1.0, 1.2, 1.4])

        let report = BenchmarkClaimGate.evaluate(
            results: results,
            options: BenchmarkClaimGateOptions(
                candidateRuntime: "conjet",
                baselineRuntimes: ["orbstack", "colima"],
                minimumSamples: 3,
                rules: rules
            )
        )

        XCTAssertTrue(report.passed)
        XCTAssertTrue(report.missingRequirements.isEmpty)
        XCTAssertTrue(report.comparisons.allSatisfy(\.passed))
    }

    func testBenchmarkClaimGateFailsWhenOrbStackEvidenceIsMissing() throws {
        let report = BenchmarkClaimGate.evaluate(
            results: makeResults(workload: "copy-node-modules", runtime: "conjet", values: [1.0, 1.1, 1.2])
                + makeResults(workload: "copy-node-modules", runtime: "colima", values: [2.0, 2.1, 2.2]),
            options: BenchmarkClaimGateOptions(
                candidateRuntime: "conjet",
                baselineRuntimes: ["orbstack", "colima"],
                minimumSamples: 3,
                rules: [BenchmarkClaimRule(workload: "copy-node-modules")]
            )
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.missingRequirements.contains { $0.contains("copy-node-modules / orbstack") })
        XCTAssertTrue(report.comparisons.contains { $0.baselineRuntime == "orbstack" && !$0.passed })
    }

    func testBenchmarkClaimGateFailsOnP95RegressionAndFailures() throws {
        var failingBaseline = makeResults(workload: "conjetfs-hot-reload", runtime: "orbstack", values: [1.0, 1.0, 1.0])
        failingBaseline[0].exitCode = 125
        let report = BenchmarkClaimGate.evaluate(
            results: makeResults(workload: "conjetfs-hot-reload", runtime: "conjet", values: [0.8, 0.9, 1.5])
                + failingBaseline,
            options: BenchmarkClaimGateOptions(
                candidateRuntime: "conjet",
                baselineRuntimes: ["orbstack"],
                minimumSamples: 3,
                rules: [BenchmarkClaimRule(workload: "conjetfs-hot-reload")]
            )
        )

        XCTAssertFalse(report.passed)
        let comparison = try XCTUnwrap(report.comparisons.first)
        XCTAssertTrue(comparison.reason.contains("baseline has 1 failures"))
        XCTAssertTrue(comparison.reason.contains("P95 ratio"))
    }

    func testBenchmarkClaimGateSupportsMappedCandidateAndBaselineWorkloads() throws {
        let rule = BenchmarkClaimRule(
            workload: "hot-reload-fast-path",
            candidateWorkload: "conjetfs-hot-reload",
            baselineWorkload: "bind-hot-reload",
            measure: .metric("hot_reload_seconds")
        )
        let results =
            makeResults(workload: "conjetfs-hot-reload", runtime: "conjet", metric: "hot_reload_seconds", values: [0.40, 0.42, 0.44]) +
            makeResults(workload: "bind-hot-reload", runtime: "orbstack", metric: "hot_reload_seconds", values: [0.60, 0.62, 0.64])

        let report = BenchmarkClaimGate.evaluate(
            results: results,
            options: BenchmarkClaimGateOptions(
                candidateRuntime: "conjet",
                baselineRuntimes: ["orbstack"],
                minimumSamples: 3,
                rules: [rule]
            )
        )

        XCTAssertTrue(report.passed)
        let comparison = try XCTUnwrap(report.comparisons.first)
        XCTAssertEqual(comparison.workload, "hot-reload-fast-path")
        XCTAssertEqual(comparison.candidateWorkload, "conjetfs-hot-reload")
        XCTAssertEqual(comparison.baselineWorkload, "bind-hot-reload")
        XCTAssertEqual(comparison.measure, "hot_reload_seconds")
    }

    func testBenchmarkClaimGatePassesMappedRuleWhenBaselineFailsAllSamples() throws {
        let rule = BenchmarkClaimRule(
            workload: "hot-reload-fast-path",
            candidateWorkload: "conjetfs-hot-reload",
            baselineWorkload: "bind-hot-reload",
            measure: .metric("hot_reload_seconds")
        )
        var failingBaseline = makeResults(workload: "bind-hot-reload", runtime: "colima", values: [1.0, 1.0, 1.0])
        for index in failingBaseline.indices {
            failingBaseline[index].exitCode = 124
        }
        let results =
            makeResults(workload: "conjetfs-hot-reload", runtime: "conjet", metric: "hot_reload_seconds", values: [0.13, 0.14, 0.15]) +
            failingBaseline

        let report = BenchmarkClaimGate.evaluate(
            results: results,
            options: BenchmarkClaimGateOptions(
                candidateRuntime: "conjet",
                baselineRuntimes: ["colima"],
                minimumSamples: 3,
                rules: [rule]
            )
        )

        XCTAssertTrue(report.passed)
        XCTAssertTrue(report.missingRequirements.isEmpty)
        let comparison = try XCTUnwrap(report.comparisons.first)
        XCTAssertTrue(comparison.passed)
        XCTAssertEqual(comparison.reason, "baseline failed all samples while candidate succeeded")
        XCTAssertEqual(comparison.baselineFailures, 3)
        XCTAssertNil(comparison.p50Ratio)
        XCTAssertNil(comparison.p95Ratio)
    }

    func testBenchmarkClaimGateFiltersBySamplePhase() throws {
        let rule = BenchmarkClaimRule(workload: "conjetfs-pnpm-install")
        let results =
            makeResults(workload: "conjetfs-pnpm-install", runtime: "conjet", values: [3.0, 3.1, 3.2], phase: .cold) +
            makeResults(workload: "conjetfs-pnpm-install", runtime: "orbstack", values: [2.0, 2.1, 2.2], phase: .cold) +
            makeResults(workload: "conjetfs-pnpm-install", runtime: "conjet", values: [1.0, 1.1, 1.2], phase: .warm) +
            makeResults(workload: "conjetfs-pnpm-install", runtime: "orbstack", values: [1.4, 1.5, 1.6], phase: .warm)

        let warmReport = BenchmarkClaimGate.evaluate(
            results: results,
            options: BenchmarkClaimGateOptions(
                candidateRuntime: "conjet",
                baselineRuntimes: ["orbstack"],
                minimumSamples: 3,
                samplePhase: .warm,
                rules: [rule]
            )
        )

        XCTAssertTrue(warmReport.passed)
        XCTAssertEqual(warmReport.samplePhase, .warm)
        XCTAssertEqual(warmReport.comparisons.first?.candidateP50, 1.1)

        let coldReport = BenchmarkClaimGate.evaluate(
            results: results,
            options: BenchmarkClaimGateOptions(
                candidateRuntime: "conjet",
                baselineRuntimes: ["orbstack"],
                minimumSamples: 3,
                samplePhase: .cold,
                rules: [rule]
            )
        )

        XCTAssertFalse(coldReport.passed)
        XCTAssertEqual(coldReport.samplePhase, .cold)
        XCTAssertEqual(coldReport.comparisons.first?.candidateP50, 3.1)
    }

    func testBenchmarkClaimGateReportsMappedMissingEvidenceWithRole() throws {
        let rule = BenchmarkClaimRule(
            workload: "hot-reload-fast-path",
            candidateWorkload: "conjetfs-hot-reload",
            baselineWorkload: "bind-hot-reload",
            measure: .metric("hot_reload_seconds")
        )
        let report = BenchmarkClaimGate.evaluate(
            results: makeResults(workload: "conjetfs-hot-reload", runtime: "conjet", metric: "hot_reload_seconds", values: [0.40, 0.42, 0.44]),
            options: BenchmarkClaimGateOptions(
                candidateRuntime: "conjet",
                baselineRuntimes: ["orbstack"],
                minimumSamples: 3,
                rules: [rule]
            )
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.missingRequirements.contains { $0.contains("hot-reload-fast-path baseline bind-hot-reload / orbstack") })
    }

    func testBenchmarkClaimGateRequiresRawJSONReports() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-gate-\(UUID().uuidString).md")
        try "# markdown\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try BenchmarkClaimGate.loadJSONReports(urls: [url])) { error in
            XCTAssertTrue(String(describing: error).contains("requires raw JSON reports"))
        }
    }

    func testBenchmarkReleaseGateRunnerWritesArtifactsAndPassesInjectedCollectors() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-release-gate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let options = BenchmarkReleaseGateOptions(
            contexts: ["conjet", "orbstack", "colima"],
            candidateRuntime: "conjet",
            baselineRuntimes: ["orbstack", "colima"],
            iterations: 2,
            minimumSamples: 2,
            workloads: ["container-start"],
            includeIdle: true,
            includePower: true,
            idleSeconds: 1,
            powerSeconds: 1,
            useSudoForPower: false
        )
        let runner = BenchmarkReleaseGateRunner(
            options: options,
            dockerCollector: { contexts, iterations, _, _, _ in
                contexts.flatMap { runtime in
                    (1...iterations).map { iteration in
                        benchmarkResult(
                            workload: "container-start",
                            runtime: runtime,
                            duration: runtime == "conjet" ? 0.4 + Double(iteration) * 0.01 : 1.0 + Double(iteration) * 0.01
                        )
                    }
                }
            },
            idleCollector: { runtime, _ in
                benchmarkResult(
                    workload: "idle-resource-sample",
                    runtime: runtime,
                    duration: 1,
                    metrics: ["cpu_percent_mean": runtime == "conjet" ? 0.1 : 0.5]
                )
            },
            powerCollector: { runtime, _ in
                benchmarkResult(
                    workload: "idle-power-sample",
                    runtime: runtime,
                    duration: 1,
                    metrics: ["combined_power_mw_mean": runtime == "conjet" ? 100 : 200]
                )
            }
        )

        let result = try runner.run(outputDirectory: directory)

        XCTAssertTrue(result.gateReport.passed)
        XCTAssertEqual(Set(result.gateReport.comparisons.map(\.workload)), [
            "container-start",
            "idle-resource-sample",
            "idle-power-sample"
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.artifacts.dockerReport))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.artifacts.allResultsReport))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.artifacts.allResultsMarkdown))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.artifacts.gateReport))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.artifacts.gateMarkdownReport))
        XCTAssertEqual(result.artifacts.idleReports.count, 3)
        XCTAssertEqual(result.artifacts.powerReports.count, 3)

        let allResults = try BenchmarkClaimGate.loadJSONReports(urls: [URL(fileURLWithPath: result.artifacts.allResultsReport)])
        XCTAssertEqual(allResults.count, 18)
    }

    func testBenchmarkReleaseGateRunnerFailsWhenOrbStackContextWasNotCollected() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-release-gate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let options = BenchmarkReleaseGateOptions(
            contexts: ["conjet", "colima"],
            candidateRuntime: "conjet",
            baselineRuntimes: ["orbstack", "colima"],
            iterations: 1,
            minimumSamples: 1,
            workloads: ["container-start"],
            includeIdle: false,
            includePower: false
        )
        let runner = BenchmarkReleaseGateRunner(
            options: options,
            dockerCollector: { contexts, iterations, _, _, _ in
                contexts.flatMap { runtime in
                    (1...iterations).map { _ in
                        benchmarkResult(
                            workload: "container-start",
                            runtime: runtime,
                            duration: runtime == "conjet" ? 0.5 : 1.0
                        )
                    }
                }
            }
        )

        let result = try runner.run(outputDirectory: directory)

        XCTAssertFalse(result.gateReport.passed)
        XCTAssertTrue(result.gateReport.missingRequirements.contains { $0.contains("container-start / orbstack") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.artifacts.gateReport))
    }

    func testBenchmarkReleaseGateRunnerSkipsDockerCollectorWhenOnlyIdleIsSelected() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-release-gate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let options = BenchmarkReleaseGateOptions(
            contexts: ["conjet", "orbstack"],
            candidateRuntime: "conjet",
            baselineRuntimes: ["orbstack"],
            iterations: 1,
            minimumSamples: 1,
            workloads: ["idle-resource-sample"],
            includeIdle: true,
            includePower: false,
            idleSeconds: 1
        )
        let runner = BenchmarkReleaseGateRunner(
            options: options,
            dockerCollector: { _, _, _, _, _ in
                XCTFail("Docker collector should not run for an idle-only release gate")
                return []
            },
            idleCollector: { runtime, _ in
                benchmarkResult(
                    workload: "idle-resource-sample",
                    runtime: runtime,
                    duration: 1,
                    metrics: ["cpu_percent_mean": runtime == "conjet" ? 0.1 : 0.5]
                )
            }
        )

        let result = try runner.run(outputDirectory: directory)

        XCTAssertTrue(result.gateReport.passed)
        XCTAssertEqual(result.gateReport.comparisons.map(\.workload), ["idle-resource-sample"])
        let dockerResults = try BenchmarkClaimGate.loadJSONReports(urls: [URL(fileURLWithPath: result.artifacts.dockerReport)])
        XCTAssertEqual(dockerResults.count, 0)
        let allResults = try BenchmarkClaimGate.loadJSONReports(urls: [URL(fileURLWithPath: result.artifacts.allResultsReport)])
        XCTAssertEqual(allResults.count, 2)
    }

    func testBenchmarkReleaseGateSelectsMappedRulesFromEitherWorkload() throws {
        let conjetFSOptions = BenchmarkReleaseGateOptions(
            workloads: ["conjetfs-hot-reload"],
            includeIdle: false,
            includePower: false
        )
        XCTAssertTrue(conjetFSOptions.effectiveGateRules.contains { $0.workload == "hot-reload-fast-path" })
        XCTAssertEqual(Set(conjetFSOptions.effectiveDockerWorkloads), ["conjetfs-hot-reload", "bind-hot-reload"])

        let bindOptions = BenchmarkReleaseGateOptions(
            workloads: ["bind-hot-reload"],
            includeIdle: false,
            includePower: false
        )
        XCTAssertTrue(bindOptions.effectiveGateRules.contains { $0.workload == "hot-reload-fast-path" })
        XCTAssertEqual(Set(bindOptions.effectiveDockerWorkloads), ["conjetfs-hot-reload", "bind-hot-reload"])
    }
}

private final class DockerCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCommands: [[String]] = []

    var commands: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCommands
    }

    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        lock.lock()
        recordedCommands.append(arguments)
        lock.unlock()
        return ProcessResult(
            executable: executable,
            arguments: arguments,
            exitCode: 0,
            stdout: "ok\n",
            stderr: ""
        )
    }

    func runWithInput(_ executable: String, _ arguments: [String], _ input: Data?) throws -> ProcessResult {
        try run(executable, arguments)
    }
}

private func makeResults(workload: String, runtime: String, values: [Double]) -> [BenchmarkResult] {
    values.map {
        BenchmarkResult(
            workload: workload,
            runtime: runtime,
            startedAt: Date(),
            durationSeconds: $0,
            exitCode: 0,
            machine: MachineProfiler.capture()
        )
    }
}

private func makeResults(
    workload: String,
    runtime: String,
    values: [Double],
    phase: BenchmarkSamplePhase
) -> [BenchmarkResult] {
    values.map {
        BenchmarkResult(
            workload: workload,
            runtime: runtime,
            startedAt: Date(),
            durationSeconds: $0,
            exitCode: 0,
            metrics: [BenchmarkSamplePhase.metricKey: phase.metricValue ?? -1],
            machine: MachineProfiler.capture()
        )
    }
}

private func makeResults(workload: String, runtime: String, metric: String, values: [Double]) -> [BenchmarkResult] {
    values.map {
        BenchmarkResult(
            workload: workload,
            runtime: runtime,
            startedAt: Date(),
            durationSeconds: 1,
            exitCode: 0,
            metrics: [metric: $0],
            machine: MachineProfiler.capture()
        )
    }
}

private func benchmarkResult(
    workload: String,
    runtime: String,
    duration: Double,
    metrics: [String: Double] = [:]
) -> BenchmarkResult {
    BenchmarkResult(
        workload: workload,
        runtime: runtime,
        startedAt: Date(),
        durationSeconds: duration,
        exitCode: 0,
        metrics: metrics,
        machine: MachineProfiler.capture()
    )
}

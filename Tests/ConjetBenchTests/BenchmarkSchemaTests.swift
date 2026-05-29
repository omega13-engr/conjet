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

    func testDockerBenchmarkSuiteBuildsRepeatableContextCommands() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-docker-bench-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = DockerCommandRecorder()
        let suite = DockerBenchmarkSuite(
            contexts: ["conjet"],
            iterations: 2,
            warmup: true,
            runner: recorder.run
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
            command.contains("--tmpfs") && command.contains("/scratch:rw,size=64m")
        })
        XCTAssertTrue(results.allSatisfy { $0.runtime == "conjet" })
        XCTAssertTrue(results.allSatisfy { !$0.command.isEmpty })
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
            runner: recorder.run
        )
        let results = try suite.run(workDirectory: directory)

        XCTAssertEqual(results.map(\.workload), ["npm-install"])
        XCTAssertEqual(results.first?.metrics["dependency_count"], 3)
        XCTAssertTrue(recorder.commands.allSatisfy { command in
            command.starts(with: ["docker", "--context", "conjet", "build"]) ||
                command.starts(with: ["docker", "--context", "conjet", "rmi"])
        })
    }
}

private final class DockerCommandRecorder {
    private(set) var commands: [[String]] = []

    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        commands.append(arguments)
        return ProcessResult(
            executable: executable,
            arguments: arguments,
            exitCode: 0,
            stdout: "ok\n",
            stderr: ""
        )
    }
}

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

        XCTAssertEqual(results.count, 8)
        XCTAssertEqual(Set(results.map(\.workload)), Set(["docker-version", "container-start", "image-build", "compose-up"]))
        XCTAssertTrue(recorder.commands.contains(["docker", "--context", "conjet", "pull", "alpine:3.20"]))
        XCTAssertTrue(recorder.commands.contains(["docker", "--context", "conjet", "pull", "busybox:1.36"]))
        XCTAssertTrue(results.allSatisfy { $0.runtime == "conjet" })
        XCTAssertTrue(results.allSatisfy { !$0.command.isEmpty })
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

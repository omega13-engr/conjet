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
        XCTAssertTrue(markdown.contains("| Workload | Runtime | Duration (s) | Exit | Key Metrics |"))
        XCTAssertTrue(markdown.contains("file_count=2"))
    }
}

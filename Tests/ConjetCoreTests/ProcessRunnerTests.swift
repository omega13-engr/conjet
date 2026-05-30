import ConjetCore
import XCTest

final class ProcessRunnerTests: XCTestCase {
    func testRunRecordsTimeoutAsProcessFailure() throws {
        let startedAt = Date()
        let result = try ProcessRunner.run(
            "/bin/sh",
            ["-c", "sleep 5"],
            timeoutSeconds: 0.1
        )

        XCTAssertEqual(result.exitCode, 124)
        XCTAssertTrue(result.stderr.contains("process timed out after"))
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }
}

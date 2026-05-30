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

    func testRunReturnsAfterTimeoutWhenProcessIgnoresTerminate() throws {
        let startedAt = Date()
        let result = try ProcessRunner.run(
            "/bin/sh",
            ["-c", "trap '' TERM; while true; do :; done"],
            timeoutSeconds: 0.1
        )

        XCTAssertEqual(result.exitCode, 124)
        XCTAssertTrue(result.stderr.contains("process timed out after"))
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 5)
    }

    func testRunWithInputTimeoutStartsBeforeChildReadsStdin() throws {
        let input = Data(repeating: 0x41, count: 8 * 1_024 * 1_024)
        let startedAt = Date()
        let result = try ProcessRunner.runWithInput(
            "/bin/sh",
            ["-c", "sleep 5"],
            standardInput: input,
            timeoutSeconds: 0.1
        )

        XCTAssertEqual(result.exitCode, 124)
        XCTAssertTrue(result.stderr.contains("process timed out after"))
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    func testRunSurvivesRepeatedPipeDraining() throws {
        for index in 0..<100 {
            let result = try ProcessRunner.run(
                "/bin/sh",
                ["-c", "printf 'stdout-\(index)'; printf 'stderr-\(index)' >&2"],
                timeoutSeconds: 2
            )

            XCTAssertEqual(result.exitCode, 0)
            XCTAssertEqual(result.stdout, "stdout-\(index)")
            XCTAssertEqual(result.stderr, "stderr-\(index)")
        }
    }
}

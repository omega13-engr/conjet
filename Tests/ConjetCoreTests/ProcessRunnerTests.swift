import ConjetCore
import Darwin
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

    func testProcessRunnerStressCleansTemporaryCaptureFiles() throws {
        let rootTemp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let temp = rootTemp.appendingPathComponent("conjet-process-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let originalTMPDIR = ProcessInfo.processInfo.environment["TMPDIR"]
        setenv("TMPDIR", temp.path + "/", 1)
        defer {
            if let originalTMPDIR {
                setenv("TMPDIR", originalTMPDIR, 1)
            } else {
                unsetenv("TMPDIR")
            }
            try? FileManager.default.removeItem(at: temp)
        }

        let before = try conjetCaptureFiles(in: temp)

        for index in 0..<500 {
            let result = try ProcessRunner.run(
                "/bin/sh",
                ["-c", "printf 'stdout-\(index)'; printf 'stderr-\(index)' >&2"],
                timeoutSeconds: 2
            )

            XCTAssertEqual(result.exitCode, 0)
            XCTAssertEqual(result.stdout, "stdout-\(index)")
            XCTAssertEqual(result.stderr, "stderr-\(index)")
            XCTAssertFalse(result.stderr.localizedCaseInsensitiveContains("bad file descriptor"))
        }

        var leaked = try conjetCaptureFiles(in: temp).subtracting(before)
        let deadline = Date().addingTimeInterval(1)
        while !leaked.isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            leaked = try conjetCaptureFiles(in: temp).subtracting(before)
        }
        XCTAssertEqual(leaked, [])
    }

    private func conjetCaptureFiles(in directory: URL) throws -> Set<String> {
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return Set(entries.filter {
            $0.hasPrefix("conjet-stdout-") ||
                $0.hasPrefix("conjet-stderr-") ||
                $0.hasPrefix("conjet-stdin-")
        })
    }
}

import Darwin
import XCTest
@testable import ConjetCore

final class DaemonProcessSupervisorTests: XCTestCase {
    func testTerminateRunningDaemonRemovesRuntimeFiles() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let pid = try launchDetachedSleep()
        defer { terminateIfRunning(pid) }
        try writeLock(pid: pid, path: fixture.lock.path)
        FileManager.default.createFile(atPath: fixture.socket.path, contents: nil)

        let supervisor = DaemonProcessSupervisor(socketPath: fixture.socket.path, expectedExecutableNames: ["sleep"])
        let termination = try supervisor.terminateRunningDaemon(timeoutSeconds: 2)

        XCTAssertEqual(termination?.pid, pid)
        XCTAssertEqual(termination?.signal, SIGTERM)
        XCTAssertFalse(DaemonProcessSupervisor.processExists(pid))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.lock.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socket.path))
    }

    func testRunningPIDIgnoresExitedProcessInLock() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let missingPID = firstMissingPID()
        try writeLock(pid: missingPID, path: fixture.lock.path)
        FileManager.default.createFile(atPath: fixture.socket.path, contents: nil)

        let supervisor = DaemonProcessSupervisor(socketPath: fixture.socket.path, expectedExecutableNames: ["sleep"])
        XCTAssertNil(supervisor.runningPID())

        let termination = try supervisor.terminateRunningDaemon(timeoutSeconds: 0.1)
        XCTAssertEqual(termination?.pid, missingPID)
        XCTAssertEqual(termination?.signal, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.lock.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socket.path))
    }

    func testCustomLockPathControlsDaemonWhenSocketPathIsElsewhere() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let socketDirectory = fixture.root.appendingPathComponent("socket", isDirectory: true)
        let lockDirectory = fixture.root.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        let socket = socketDirectory.appendingPathComponent("custom-conjetd.sock")
        let lock = lockDirectory.appendingPathComponent("conjetd.lock")

        let pid = try launchDetachedSleep()
        defer { terminateIfRunning(pid) }
        try writeLock(pid: pid, path: lock.path)
        FileManager.default.createFile(atPath: socket.path, contents: nil)

        let supervisor = DaemonProcessSupervisor(
            socketPath: socket.path,
            lockPath: lock.path,
            expectedExecutableNames: ["sleep"]
        )

        XCTAssertEqual(supervisor.runningPID(), pid)
        let termination = try supervisor.terminateRunningDaemon(timeoutSeconds: 2)
        XCTAssertEqual(termination?.pid, pid)
        XCTAssertFalse(DaemonProcessSupervisor.processExists(pid))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
    }

    func testRefusesToTerminateUnexpectedExecutable() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let pid = try launchDetachedSleep()
        defer { terminateIfRunning(pid) }
        try writeLock(pid: pid, path: fixture.lock.path)

        let supervisor = DaemonProcessSupervisor(socketPath: fixture.socket.path, expectedExecutableNames: ["conjetd"])
        XCTAssertThrowsError(try supervisor.terminateRunningDaemon(timeoutSeconds: 0.1)) { error in
            XCTAssertTrue(String(describing: error).contains("refusing to terminate pid \(pid)"))
        }
        XCTAssertTrue(DaemonProcessSupervisor.processExists(pid))
    }

    private func makeFixture() throws -> (root: URL, socket: URL, lock: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conjet-daemon-supervisor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (
            root: root,
            socket: root.appendingPathComponent("conjetd.sock"),
            lock: root.appendingPathComponent("conjetd.lock")
        )
    }

    private func writeLock(pid: Int32, path: String) throws {
        try "\(pid)\n".write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func launchDetachedSleep() throws -> Int32 {
        let result = try ProcessRunner.run(
            "/bin/sh",
            ["-c", "/bin/sleep 30 >/dev/null 2>&1 & echo $!"],
            timeoutSeconds: 2
        )
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, let pid = Int32(text), pid > 0 else {
            throw ConjetError.processFailed(executable: result.executable, exitCode: result.exitCode, stderr: result.stderr)
        }
        return pid
    }

    private func firstMissingPID() -> Int32 {
        for pid in stride(from: 900_000, through: 800_000, by: -1) {
            let candidate = Int32(pid)
            if !DaemonProcessSupervisor.processExists(candidate) {
                return candidate
            }
        }
        return 999_999
    }

    private func terminateIfRunning(_ pid: Int32) {
        guard DaemonProcessSupervisor.processExists(pid) else { return }
        Darwin.kill(pid, SIGKILL)
    }
}

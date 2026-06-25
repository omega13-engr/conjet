import Darwin
import Foundation

public struct DaemonProcessTermination: Equatable, Sendable {
    public var pid: Int32
    public var signal: Int32
    public var removedRuntimePaths: [String]

    public init(pid: Int32, signal: Int32, removedRuntimePaths: [String]) {
        self.pid = pid
        self.signal = signal
        self.removedRuntimePaths = removedRuntimePaths
    }
}

public struct DaemonProcessSupervisor: Sendable {
    public static let canonicalExecutableName = "conjetd"
    public static let legacyExecutableNames: Set<String> = ["Conjet Core", "conjet-core"]
    public static let executableNamesForTermination: Set<String> = Set([canonicalExecutableName])
        .union(legacyExecutableNames)

    public var socketPath: String
    public var lockPath: String
    public var expectedExecutableNames: Set<String>

    public init(
        socketPath: String,
        lockPath: String? = nil,
        expectedExecutableNames: Set<String> = [Self.canonicalExecutableName]
    ) {
        self.socketPath = socketPath
        self.lockPath = lockPath ?? Self.defaultLockPath(socketPath: socketPath)
        self.expectedExecutableNames = expectedExecutableNames
    }

    public static func defaultLockPath(socketPath: String) -> String {
        URL(fileURLWithPath: socketPath)
            .deletingLastPathComponent()
            .appendingPathComponent("conjetd.lock")
            .path
    }

    public func runningPID() -> Int32? {
        guard let pid = lockedPID(), Self.processExists(pid) else {
            return nil
        }
        guard processLooksExpected(pid) else {
            return nil
        }
        return pid
    }

    @discardableResult
    public func terminateRunningDaemon(timeoutSeconds: Double = 5) throws -> DaemonProcessTermination? {
        guard let pid = lockedPID() else {
            removeRuntimeFiles()
            return nil
        }
        guard Self.processExists(pid) else {
            let removed = removeRuntimeFiles()
            return DaemonProcessTermination(pid: pid, signal: 0, removedRuntimePaths: removed)
        }
        guard processLooksExpected(pid) else {
            let executable = Self.executablePath(pid: pid) ?? Self.commandPath(pid: pid) ?? "unknown"
            throw ConjetError.unavailable(
                "refusing to terminate pid \(pid) from \(lockPath); executable '\(executable)' does not look like \(expectedExecutableDescription)"
            )
        }

        try send(signal: SIGTERM, to: pid)
        if waitForExit(pid: pid, timeoutSeconds: timeoutSeconds) {
            let removed = removeRuntimeFiles()
            return DaemonProcessTermination(pid: pid, signal: SIGTERM, removedRuntimePaths: removed)
        }

        try send(signal: SIGKILL, to: pid)
        if waitForExit(pid: pid, timeoutSeconds: 2) {
            let removed = removeRuntimeFiles()
            return DaemonProcessTermination(pid: pid, signal: SIGKILL, removedRuntimePaths: removed)
        }

        throw ConjetError.unavailable("Conjet Core pid \(pid) did not exit after SIGTERM and SIGKILL")
    }

    @discardableResult
    public func removeRuntimeFiles() -> [String] {
        let manager = FileManager.default
        var removed: [String] = []
        for path in [socketPath, lockPath] {
            guard manager.fileExists(atPath: path) else { continue }
            do {
                try manager.removeItem(atPath: path)
                removed.append(path)
            } catch {
                continue
            }
        }
        return removed
    }

    public func lockedPID() -> Int32? {
        guard let raw = try? String(contentsOfFile: lockPath, encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else {
            return nil
        }
        return pid
    }

    public static func processExists(_ pid: Int32) -> Bool {
        errno = 0
        if Darwin.kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    public static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let count = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
        }
        guard count > 0 else {
            return nil
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func commandPath(pid: Int32) -> String? {
        guard let result = try? ProcessRunner.run(
            "/bin/ps",
            ["-ww", "-p", String(pid), "-o", "comm="],
            timeoutSeconds: 2
        ), result.succeeded else {
            return nil
        }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private var expectedExecutableDescription: String {
        expectedExecutableNames.sorted().joined(separator: " or ")
    }

    private func processLooksExpected(_ pid: Int32) -> Bool {
        guard let executablePath = Self.executablePath(pid: pid) ?? Self.commandPath(pid: pid) else {
            return false
        }
        let executableName = URL(fileURLWithPath: executablePath).lastPathComponent
        return expectedExecutableNames.contains(executableName)
    }

    private func send(signal: Int32, to pid: Int32) throws {
        errno = 0
        guard Darwin.kill(pid, signal) == 0 else {
            if errno == ESRCH {
                return
            }
            throw ConjetError.unavailable(
                "failed to signal Conjet Core pid \(pid) with \(signal): \(String(cString: strerror(errno)))"
            )
        }
    }

    private func waitForExit(pid: Int32, timeoutSeconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(max(0.1, timeoutSeconds))
        while Date() < deadline {
            if !Self.processExists(pid) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !Self.processExists(pid)
    }
}

import Foundation
#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

public struct ProcessResult: Codable, Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(
        executable: String,
        arguments: [String],
        exitCode: Int32,
        stdout: String,
        stderr: String
    ) {
        self.executable = executable
        self.arguments = arguments
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { exitCode == 0 }
}

public enum ProcessRunner {
    public static func run(_ executable: String, _ arguments: [String] = []) throws -> ProcessResult {
        try runWithInput(executable, arguments, standardInput: nil)
    }

    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        timeoutSeconds: Double?
    ) throws -> ProcessResult {
        try runWithInput(executable, arguments, standardInput: nil, timeoutSeconds: timeoutSeconds)
    }

    public static func runWithInput(
        _ executable: String,
        _ arguments: [String] = [],
        standardInput: Data?
    ) throws -> ProcessResult {
        try runWithInput(executable, arguments, standardInput: standardInput, timeoutSeconds: nil)
    }

    public static func runWithInput(
        _ executable: String,
        _ arguments: [String] = [],
        standardInput: Data?,
        timeoutSeconds: Double?
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = standardInput == nil ? nil : Pipe()
        let stdoutData = LockedProcessData()
        let stderrData = LockedProcessData()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let stdinPipe {
            process.standardInput = stdinPipe
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stdoutData.append(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stderrData.append(data)
            }
        }

        try process.run()
        if let standardInput, let stdinPipe {
            stdinPipe.fileHandleForWriting.write(standardInput)
            try? stdinPipe.fileHandleForWriting.close()
        }

        let waitSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            waitSemaphore.signal()
        }

        var timedOut = false
        if let timeoutSeconds {
            let timeout = max(0.1, timeoutSeconds)
            if waitSemaphore.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                process.terminate()
                if waitSemaphore.wait(timeout: .now() + 2) == .timedOut {
                    #if os(macOS) || os(Linux)
                    kill(process.processIdentifier, SIGKILL)
                    #endif
                    waitSemaphore.wait()
                }
            }
        } else {
            waitSemaphore.wait()
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingStdout.isEmpty {
            stdoutData.append(remainingStdout)
        }
        let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingStderr.isEmpty {
            stderrData.append(remainingStderr)
        }

        let stdout = String(data: stdoutData.data(), encoding: .utf8) ?? ""
        var stderr = String(data: stderrData.data(), encoding: .utf8) ?? ""
        if timedOut {
            let timeout = String(format: "%.3f", timeoutSeconds ?? 0)
            let message = "process timed out after \(timeout)s"
            stderr = stderr.isEmpty ? message : stderr + "\n" + message
        }

        return ProcessResult(
            executable: executable,
            arguments: arguments,
            exitCode: timedOut ? 124 : process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }
}

private final class LockedProcessData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    func data() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

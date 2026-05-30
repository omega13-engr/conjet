import Foundation

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

    public static func runWithInput(
        _ executable: String,
        _ arguments: [String] = [],
        standardInput: Data?
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
        process.waitUntilExit()

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
        let stderr = String(data: stderrData.data(), encoding: .utf8) ?? ""

        return ProcessResult(
            executable: executable,
            arguments: arguments,
            exitCode: process.terminationStatus,
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

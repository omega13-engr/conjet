import Foundation

public struct ProcessResult: Codable, Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public var succeeded: Bool { exitCode == 0 }
}

public enum ProcessRunner {
    public static func run(_ executable: String, _ arguments: [String] = []) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        return ProcessResult(
            executable: executable,
            arguments: arguments,
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }
}

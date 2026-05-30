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

        var stdinFileHandle: FileHandle?
        var stdinFileURL: URL?
        let outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let stdoutURL = outputDirectory.appendingPathComponent("conjet-stdout-\(UUID().uuidString)")
        let stderrURL = outputDirectory.appendingPathComponent("conjet-stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        if let standardInput {
            let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("conjet-stdin-\(UUID().uuidString)")
            try standardInput.write(to: url, options: .atomic)
            let handle = try FileHandle(forReadingFrom: url)
            stdinFileURL = url
            stdinFileHandle = handle
            process.standardInput = handle
        }
        defer {
            try? stdinFileHandle?.close()
            try? stdoutHandle.close()
            try? stderrHandle.close()
            if let stdinFileURL {
                try? FileManager.default.removeItem(at: stdinFileURL)
            }
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
        }

        let waitSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            waitSemaphore.signal()
        }

        try process.run()

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
                    _ = waitSemaphore.wait(timeout: .now() + 2)
                }
            }
        } else {
            waitSemaphore.wait()
        }

        try? stdoutHandle.close()
        try? stderrHandle.close()

        let stdoutData = (try? Data(contentsOf: stdoutURL)) ?? Data()
        let stderrData = (try? Data(contentsOf: stderrURL)) ?? Data()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        var stderr = String(data: stderrData, encoding: .utf8) ?? ""
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

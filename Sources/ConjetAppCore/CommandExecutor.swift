import ConjetCore
import Foundation
#if os(macOS)
import Darwin
#endif

public struct CommandInvocation: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var displayName: String?
    public var workingDirectory: URL?
    public var environment: [String: String]
    public var timeoutSeconds: Double?

    public init(
        executable: String,
        arguments: [String] = [],
        displayName: String? = nil,
        workingDirectory: URL? = nil,
        environment: [String: String] = [:],
        timeoutSeconds: Double? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.displayName = displayName
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeoutSeconds = timeoutSeconds
    }

    public var commandLine: String {
        ([executable] + arguments).map(Self.shellQuoted).joined(separator: " ")
    }

    private static func shellQuoted(_ value: String) -> String {
        if value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
           !value.contains("'"),
           !value.contains("\"") {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public struct CommandLogEntry: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    public var commandLine: String
    public var startedAt: Date
    public var finishedAt: Date
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(
        id: UUID = UUID(),
        label: String,
        commandLine: String,
        startedAt: Date,
        finishedAt: Date,
        exitCode: Int32,
        stdout: String,
        stderr: String
    ) {
        self.id = id
        self.label = label
        self.commandLine = commandLine
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { exitCode == 0 }
    public var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
}

public protocol CommandExecuting: Sendable {
    func run(_ invocation: CommandInvocation) async -> ProcessResult
}

public struct LocalCommandExecutor: CommandExecuting {
    public init() {}

    public func run(_ invocation: CommandInvocation) async -> ProcessResult {
        await Task.detached(priority: .utility) {
            Self.runSynchronously(invocation)
        }.value
    }

    private static func runSynchronously(_ invocation: CommandInvocation) -> ProcessResult {
        do {
            return try execute(invocation)
        } catch {
            return ProcessResult(
                executable: invocation.executable,
                arguments: invocation.arguments,
                exitCode: 127,
                stdout: "",
                stderr: String(describing: error)
            )
        }
    }

    private static func execute(_ invocation: CommandInvocation) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        process.currentDirectoryURL = invocation.workingDirectory
        if !invocation.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(invocation.environment) { _, new in new }
        }

        let outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let stdoutURL = outputDirectory.appendingPathComponent("conjet-app-stdout-\(UUID().uuidString)")
        let stderrURL = outputDirectory.appendingPathComponent("conjet-app-stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
        }

        let waitSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in waitSemaphore.signal() }
        try process.run()

        var timedOut = false
        if let timeoutSeconds = invocation.timeoutSeconds {
            if waitSemaphore.wait(timeout: .now() + max(0.1, timeoutSeconds)) == .timedOut {
                timedOut = true
                process.terminate()
                if waitSemaphore.wait(timeout: .now() + 2) == .timedOut {
                    #if os(macOS)
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
        let stdout = String(data: (try? Data(contentsOf: stdoutURL)) ?? Data(), encoding: .utf8) ?? ""
        var stderr = String(data: (try? Data(contentsOf: stderrURL)) ?? Data(), encoding: .utf8) ?? ""
        if timedOut {
            let timeout = String(format: "%.1f", invocation.timeoutSeconds ?? 0)
            let message = "process timed out after \(timeout)s"
            stderr = stderr.isEmpty ? message : stderr + "\n" + message
        }

        return ProcessResult(
            executable: invocation.executable,
            arguments: invocation.arguments,
            exitCode: timedOut ? 124 : process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }
}

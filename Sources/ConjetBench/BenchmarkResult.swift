import ConjetCore
import Foundation

public struct BenchmarkResult: Codable, Equatable, Sendable {
    public var workload: String
    public var runtime: String
    public var traceID: String?
    public var command: [String]
    public var startedAt: Date
    public var durationSeconds: Double
    public var exitCode: Int32
    public var metrics: [String: Double]
    public var machine: MachineProfile
    public var stdoutTail: String
    public var stderrTail: String

    public init(
        workload: String,
        runtime: String,
        traceID: String? = nil,
        command: [String] = [],
        startedAt: Date,
        durationSeconds: Double,
        exitCode: Int32,
        metrics: [String: Double] = [:],
        machine: MachineProfile,
        stdoutTail: String = "",
        stderrTail: String = ""
    ) {
        self.workload = workload
        self.runtime = runtime
        self.traceID = traceID ?? Self.makeTraceID(workload: workload, runtime: runtime, startedAt: startedAt)
        self.command = command
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.exitCode = exitCode
        self.metrics = metrics
        self.machine = machine
        self.stdoutTail = stdoutTail
        self.stderrTail = stderrTail
    }

    public static func makeTraceID(workload: String, runtime: String, startedAt: Date = Date()) -> String {
        let milliseconds = Int((startedAt.timeIntervalSince1970 * 1_000).rounded())
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return [
            "bench",
            traceComponent(workload),
            traceComponent(runtime),
            String(milliseconds),
            suffix
        ].joined(separator: "-")
    }

    public static func traceComponent(_ value: String) -> String {
        let scalars = value.lowercased().unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == "." {
                return Character(scalar)
            }
            return "-"
        }
        let collapsed = String(scalars).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return collapsed.isEmpty ? "unknown" : collapsed
    }
}

public struct CommandBenchmarkRunner: Sendable {
    public init() {}

    public func run(
        workload: String,
        runtime: String,
        executable: String,
        arguments: [String]
    ) throws -> BenchmarkResult {
        let machine = MachineProfiler.capture()
        let startedAt = Date()
        let result = try ProcessRunner.run(executable, arguments)
        let duration = Date().timeIntervalSince(startedAt)
        return BenchmarkResult(
            workload: workload,
            runtime: runtime,
            command: [executable] + arguments,
            startedAt: startedAt,
            durationSeconds: duration,
            exitCode: result.exitCode,
            machine: machine,
            stdoutTail: tail(result.stdout),
            stderrTail: tail(result.stderr)
        )
    }

    private func tail(_ text: String, limit: Int = 4096) -> String {
        if text.count <= limit { return text }
        return String(text.suffix(limit))
    }
}

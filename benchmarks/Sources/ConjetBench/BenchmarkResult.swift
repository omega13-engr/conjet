import ConjetCore
import Foundation

public enum BenchmarkMetricValue: Codable, Equatable, Sendable {
    case number(Double)
    case bool(Bool)
    case string(String)
    case stringArray([String])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String].self) {
            self = .stringArray(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "benchmark metric must be a number, bool, string, string array, or null"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .stringArray(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let value):
            return value
        case .bool(let value):
            return value ? 1 : 0
        case .string, .stringArray, .null:
            return nil
        }
    }

    public var summaryValue: String {
        switch self {
        case .number(let value):
            if value.rounded() == value {
                return String(format: "%.0f", value)
            }
            return String(format: "%.3f", value)
        case .bool(let value):
            return value ? "true" : "false"
        case .string(let value):
            return value
        case .stringArray(let value):
            return "[" + value.joined(separator: ",") + "]"
        case .null:
            return "null"
        }
    }
}

extension BenchmarkMetricValue: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral {
    public init(integerLiteral value: Int) {
        self = .number(Double(value))
    }

    public init(floatLiteral value: Double) {
        self = .number(value)
    }

    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }

    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public init(arrayLiteral elements: String...) {
        self = .stringArray(elements)
    }
}

public struct BenchmarkMetrics: Codable, Equatable, Sendable, ExpressibleByDictionaryLiteral, Sequence {
    private var storage: [String: BenchmarkMetricValue]

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.storage = try container.decode([String: BenchmarkMetricValue].self)
    }

    public init() {
        self.storage = [:]
    }

    public init(_ storage: [String: BenchmarkMetricValue]) {
        self.storage = storage
    }

    public init(_ numeric: [String: Double]) {
        self.storage = numeric.mapValues { .number($0) }
    }

    public init(dictionaryLiteral elements: (String, BenchmarkMetricValue)...) {
        self.storage = Dictionary(uniqueKeysWithValues: elements)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storage)
    }

    public subscript(_ key: String) -> Double? {
        get { storage[key]?.doubleValue }
        set {
            if let newValue {
                storage[key] = .number(newValue)
            } else {
                storage.removeValue(forKey: key)
            }
        }
    }

    public func value(for key: String) -> BenchmarkMetricValue? {
        storage[key]
    }

    public mutating func set(_ value: BenchmarkMetricValue, for key: String) {
        storage[key] = value
    }

    public mutating func setString(_ value: String, for key: String) {
        storage[key] = .string(value)
    }

    public mutating func setBool(_ value: Bool, for key: String) {
        storage[key] = .bool(value)
    }

    public mutating func setStringArray(_ value: [String], for key: String) {
        storage[key] = .stringArray(value)
    }

    public mutating func setNull(for key: String) {
        storage[key] = .null
    }

    public mutating func merge(_ other: BenchmarkMetrics) {
        for (key, value) in other.storage {
            storage[key] = value
        }
    }

    public func makeIterator() -> Dictionary<String, BenchmarkMetricValue>.Iterator {
        storage.makeIterator()
    }

    public var sortedPairs: [(key: String, value: BenchmarkMetricValue)] {
        storage.sorted { $0.key < $1.key }
    }
}

public struct BenchmarkResult: Codable, Equatable, Sendable {
    public var workload: String
    public var runtime: String
    public var traceID: String?
    public var command: [String]
    public var startedAt: Date
    public var durationSeconds: Double
    public var exitCode: Int32
    public var metrics: BenchmarkMetrics
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
        metrics: BenchmarkMetrics = [:],
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

    public init(
        workload: String,
        runtime: String,
        traceID: String? = nil,
        command: [String] = [],
        startedAt: Date,
        durationSeconds: Double,
        exitCode: Int32,
        metrics: [String: Double],
        machine: MachineProfile,
        stdoutTail: String = "",
        stderrTail: String = ""
    ) {
        self.init(
            workload: workload,
            runtime: runtime,
            traceID: traceID,
            command: command,
            startedAt: startedAt,
            durationSeconds: durationSeconds,
            exitCode: exitCode,
            metrics: BenchmarkMetrics(metrics),
            machine: machine,
            stdoutTail: stdoutTail,
            stderrTail: stderrTail
        )
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

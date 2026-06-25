import Darwin
import Foundation

public enum StartupTimelineEventID: String, Codable, CaseIterable, Hashable, Sendable {
    case t0 = "T0"
    case t1 = "T1"
    case t2 = "T2"
    case t3 = "T3"
    case t4 = "T4"
    case t5 = "T5"
    case t6 = "T6"
    case t7 = "T7"
    case td = "TD"

    public var description: String {
        switch self {
        case .t0: return "request accepted"
        case .t1: return "plan/cache ready"
        case .t2: return "RAM mapped and VM created"
        case .t3: return "first guest instruction"
        case .t4: return "PID 1 control channel ready"
        case .t5: return "OCI bundle mounted/configured"
        case .t6: return "target process first instruction"
        case .t7: return "first useful response/exit"
        case .td: return "Docker API ready"
        }
    }

    fileprivate var orderingRank: Int {
        switch self {
        case .t0: return 0
        case .t1: return 1
        case .t2: return 2
        case .t3: return 3
        case .t4: return 4
        case .t5: return 5
        case .t6: return 6
        case .t7: return 7
        case .td: return 8
        }
    }
}

public struct StartupTimelineEvent: Codable, Equatable, Sendable {
    public var id: StartupTimelineEventID
    public var sequence: Int
    public var label: String
    public var detail: String?
    public var hostContinuousNanoseconds: UInt64
    public var offsetNanoseconds: UInt64
    public var metrics: [String: Double]

    public init(
        id: StartupTimelineEventID,
        sequence: Int,
        label: String,
        detail: String? = nil,
        hostContinuousNanoseconds: UInt64,
        offsetNanoseconds: UInt64,
        metrics: [String: Double] = [:]
    ) {
        self.id = id
        self.sequence = sequence
        self.label = label
        self.detail = detail
        self.hostContinuousNanoseconds = hostContinuousNanoseconds
        self.offsetNanoseconds = offsetNanoseconds
        self.metrics = metrics
    }
}

public struct StartupTimelineTrace: Codable, Equatable, Sendable {
    public var traceID: String
    public var label: String
    public var startedAt: Date
    public var startContinuousNanoseconds: UInt64
    public var events: [StartupTimelineEvent]

    public init(
        traceID: String,
        label: String,
        startedAt: Date,
        startContinuousNanoseconds: UInt64,
        events: [StartupTimelineEvent]
    ) {
        self.traceID = traceID
        self.label = label
        self.startedAt = startedAt
        self.startContinuousNanoseconds = startContinuousNanoseconds
        self.events = events
    }

    public var completeOrdered: Bool {
        do {
            try StartupTimelineValidator.validate(self)
            return true
        } catch {
            return false
        }
    }

    public func durationNanoseconds(from start: StartupTimelineEventID, to end: StartupTimelineEventID) -> UInt64? {
        guard let startEvent = events.first(where: { $0.id == start }),
              let endEvent = events.last(where: { $0.id == end }),
              endEvent.hostContinuousNanoseconds >= startEvent.hostContinuousNanoseconds else {
            return nil
        }
        return endEvent.hostContinuousNanoseconds - startEvent.hostContinuousNanoseconds
    }

    public func jsonLines(pretty: Bool = false) throws -> String {
        try events.map { try ConjetJSON.string($0, pretty: pretty) }.joined(separator: "\n") + "\n"
    }
}

public final class StartupTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private let traceID: String
    private let label: String
    private let startedAt: Date
    private let startContinuousNanoseconds: UInt64
    private var events: [StartupTimelineEvent] = []

    public init(
        traceID: String = UUID().uuidString,
        label: String,
        startedAt: Date = Date(),
        clock: () -> UInt64 = ContinuousHostClock.nanoseconds
    ) {
        self.traceID = traceID
        self.label = label
        self.startedAt = startedAt
        self.startContinuousNanoseconds = clock()
    }

    @discardableResult
    public func record(
        _ id: StartupTimelineEventID,
        label eventLabel: String? = nil,
        detail: String? = nil,
        metrics: [String: Double] = [:],
        clock: () -> UInt64 = ContinuousHostClock.nanoseconds
    ) -> StartupTimelineEvent {
        let now = clock()
        lock.lock()
        let sequence = events.count
        let offset = now >= startContinuousNanoseconds ? now - startContinuousNanoseconds : 0
        let event = StartupTimelineEvent(
            id: id,
            sequence: sequence,
            label: eventLabel ?? id.description,
            detail: detail,
            hostContinuousNanoseconds: now,
            offsetNanoseconds: offset,
            metrics: metrics
        )
        events.append(event)
        lock.unlock()
        return event
    }

    public func snapshot() -> StartupTimelineTrace {
        lock.lock()
        defer { lock.unlock() }
        return StartupTimelineTrace(
            traceID: traceID,
            label: label,
            startedAt: startedAt,
            startContinuousNanoseconds: startContinuousNanoseconds,
            events: events
        )
    }
}

public enum StartupTimelineValidator {
    public static func validate(_ trace: StartupTimelineTrace) throws {
        guard !trace.events.isEmpty else {
            throw ConjetError.invalidArgument("startup timeline has no events")
        }
        guard trace.events.first?.id == .t0 else {
            throw ConjetError.invalidArgument("startup timeline must start with T0")
        }

        var previousSequence = -1
        var previousNanos = trace.startContinuousNanoseconds
        var previousRank = -1
        var seenRequired = Set<StartupTimelineEventID>()
        for event in trace.events {
            guard event.sequence == previousSequence + 1 else {
                throw ConjetError.invalidArgument("startup timeline event sequence is not contiguous at \(event.id.rawValue)")
            }
            guard event.hostContinuousNanoseconds >= previousNanos else {
                throw ConjetError.invalidArgument("startup timeline event \(event.id.rawValue) moved backwards in host time")
            }
            if event.id != .td {
                guard event.id.orderingRank >= previousRank else {
                    throw ConjetError.invalidArgument("startup timeline event \(event.id.rawValue) is out of order")
                }
                previousRank = event.id.orderingRank
                seenRequired.insert(event.id)
            }
            previousSequence = event.sequence
            previousNanos = event.hostContinuousNanoseconds
        }

        guard seenRequired.contains(.t7) else {
            throw ConjetError.invalidArgument("startup timeline must include T7")
        }
    }
}

public enum ContinuousHostClock {
    public static func nanoseconds() -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ticks = mach_continuous_time()
        let numer = Double(info.numer == 0 ? 1 : info.numer)
        let denom = Double(info.denom == 0 ? 1 : info.denom)
        return UInt64((Double(ticks) * numer / denom).rounded())
    }
}

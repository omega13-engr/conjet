import Foundation

public enum ConjetPulseEventType: String, Codable, Equatable, Sendable {
    case daemonStarted = "daemon.started"
    case daemonStopping = "daemon.stopping"
    case vmStarting = "vm.starting"
    case vmStarted = "vm.started"
    case vmStopping = "vm.stopping"
    case vmStopped = "vm.stopped"
    case vmErrored = "vm.errored"
    case containerCreated = "container.created"
    case containerStarted = "container.started"
    case containerStopped = "container.stopped"
    case containerRemoved = "container.removed"
    case imageChanged = "image.changed"
    case volumeChanged = "volume.changed"
    case networkChanged = "network.changed"
    case clockRepaired = "clock.repaired"
    case cachePruned = "cache.pruned"
    case memoryReclaimed = "memory.reclaimed"
    case dockerRunFinished = "docker.run.finished"
    case commandFinished = "command.finished"
}

public enum ConjetPulseDeliveryClass: String, Codable, Equatable, Sendable {
    case durable
    case sample
}

public struct ConjetPulseEvent: Codable, Equatable, Sendable {
    public var seq: UInt64
    public var type: ConjetPulseEventType
    public var deliveryClass: ConjetPulseDeliveryClass
    public var at: Date
    public var subjectID: String?
    public var message: String
    public var payload: [String: String]

    public init(
        seq: UInt64,
        type: ConjetPulseEventType,
        deliveryClass: ConjetPulseDeliveryClass = .durable,
        at: Date = Date(),
        subjectID: String? = nil,
        message: String = "",
        payload: [String: String] = [:]
    ) {
        self.seq = seq
        self.type = type
        self.deliveryClass = deliveryClass
        self.at = at
        self.subjectID = subjectID
        self.message = message
        self.payload = payload
    }
}

public struct ConjetPulseState: Codable, Equatable, Sendable {
    public var highWatermark: UInt64
    public var replayAvailableFrom: UInt64

    public init(highWatermark: UInt64, replayAvailableFrom: UInt64) {
        self.highWatermark = highWatermark
        self.replayAvailableFrom = replayAvailableFrom
    }
}

public struct ConjetPulseReplay: Codable, Equatable, Sendable {
    public var state: ConjetPulseState
    public var events: [ConjetPulseEvent]
    public var overflowed: Bool

    public init(state: ConjetPulseState, events: [ConjetPulseEvent], overflowed: Bool = false) {
        self.state = state
        self.events = events
        self.overflowed = overflowed
    }
}

public enum ConjetPulseFrameKind: String, Codable, Equatable, Sendable {
    case replay
    case events
    case heartbeat
}

public struct ConjetPulseFrame: Codable, Equatable, Sendable {
    public var kind: ConjetPulseFrameKind
    public var state: ConjetPulseState
    public var events: [ConjetPulseEvent]
    public var overflowed: Bool
    public var message: String?

    public init(
        kind: ConjetPulseFrameKind,
        state: ConjetPulseState,
        events: [ConjetPulseEvent] = [],
        overflowed: Bool = false,
        message: String? = nil
    ) {
        self.kind = kind
        self.state = state
        self.events = events
        self.overflowed = overflowed
        self.message = message
    }

    public static func replay(_ replay: ConjetPulseReplay) -> ConjetPulseFrame {
        ConjetPulseFrame(
            kind: .replay,
            state: replay.state,
            events: replay.events,
            overflowed: replay.overflowed,
            message: replay.overflowed ? "requested sequence is outside the replay window" : nil
        )
    }

    public static func events(_ replay: ConjetPulseReplay) -> ConjetPulseFrame {
        ConjetPulseFrame(
            kind: .events,
            state: replay.state,
            events: replay.events,
            overflowed: replay.overflowed,
            message: replay.overflowed ? "subscriber missed durable events; reload snapshot" : nil
        )
    }

    public static func heartbeat(state: ConjetPulseState) -> ConjetPulseFrame {
        ConjetPulseFrame(kind: .heartbeat, state: state)
    }
}

public final class ConjetPulseLog: @unchecked Sendable {
    private let capacity: Int
    private let condition = NSCondition()
    private var nextSequence: UInt64 = 1
    private var events: [ConjetPulseEvent] = []

    public init(capacity: Int = 4096) {
        self.capacity = max(1, capacity)
    }

    @discardableResult
    public func append(
        type: ConjetPulseEventType,
        deliveryClass: ConjetPulseDeliveryClass = .durable,
        subjectID: String? = nil,
        message: String = "",
        payload: [String: String] = [:],
        at: Date = Date()
    ) -> ConjetPulseEvent {
        condition.lock()
        let event = ConjetPulseEvent(
            seq: nextSequence,
            type: type,
            deliveryClass: deliveryClass,
            at: at,
            subjectID: subjectID,
            message: message,
            payload: payload
        )
        nextSequence += 1
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
        condition.broadcast()
        condition.unlock()
        return event
    }

    public func state() -> ConjetPulseState {
        condition.lock()
        defer { condition.unlock() }
        return stateLocked()
    }

    public func replay(after sequence: UInt64) -> ConjetPulseReplay {
        condition.lock()
        defer { condition.unlock() }
        return replayLocked(after: sequence)
    }

    public func waitForReplay(after sequence: UInt64, timeout: TimeInterval) -> ConjetPulseReplay {
        condition.lock()
        defer { condition.unlock() }

        if hasEvents(after: sequence) {
            return replayLocked(after: sequence)
        }

        let deadline = Date().addingTimeInterval(max(0.001, timeout))
        while !hasEvents(after: sequence) {
            if !condition.wait(until: deadline) {
                break
            }
        }
        return replayLocked(after: sequence)
    }

    private func hasEvents(after sequence: UInt64) -> Bool {
        events.last.map { $0.seq > sequence } ?? false
    }

    private func replayLocked(after sequence: UInt64) -> ConjetPulseReplay {
        let state = stateLocked()
        let firstAvailable = events.first?.seq
        let overflowed = firstAvailable.map { first in
            first > 1 && sequence < first - 1
        } ?? false
        return ConjetPulseReplay(
            state: state,
            events: events.filter { $0.seq > sequence },
            overflowed: overflowed
        )
    }

    private func stateLocked() -> ConjetPulseState {
        ConjetPulseState(
            highWatermark: nextSequence - 1,
            replayAvailableFrom: events.first?.seq ?? nextSequence
        )
    }
}

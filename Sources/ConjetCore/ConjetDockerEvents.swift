import Foundation

public struct ConjetDockerRuntimeEvent: Codable, Equatable, Sendable {
    public var type: String?
    public var status: String?
    public var action: String?
    public var id: String?
    public var from: String?
    public var time: Int64?
    public var timeNano: Int64?
    public var actor: ConjetDockerRuntimeEventActor?

    public init(
        type: String? = nil,
        status: String? = nil,
        action: String? = nil,
        id: String? = nil,
        from: String? = nil,
        time: Int64? = nil,
        timeNano: Int64? = nil,
        actor: ConjetDockerRuntimeEventActor? = nil
    ) {
        self.type = type
        self.status = status
        self.action = action
        self.id = id
        self.from = from
        self.time = time
        self.timeNano = timeNano
        self.actor = actor
    }

    public var objectType: String {
        let candidates = [
            type,
            actor?.attributes["type"],
            actor?.attributes["Type"]
        ]
        return candidates.compactMap { $0 }.first { !$0.isEmpty }?.lowercased() ?? ""
    }

    public var eventName: String {
        (action ?? status ?? "").lowercased()
    }

    public var actorID: String? {
        guard let id = actor?.id, !id.isEmpty else { return nil }
        return id
    }

    public var containerID: String? {
        guard objectType == "container" || objectType.isEmpty else { return nil }
        if let id, !id.isEmpty { return id }
        return actorID
    }

    public var subjectID: String? {
        if let id, !id.isEmpty { return id }
        return actorID
    }

    public var occurredAt: Date? {
        if let timeNano, timeNano > 0 {
            return Date(timeIntervalSince1970: Double(timeNano) / 1_000_000_000)
        }
        if let time, time > 0 {
            return Date(timeIntervalSince1970: Double(time))
        }
        return nil
    }

    public var pulseEventType: ConjetPulseEventType? {
        switch objectType {
        case "container", "":
            switch eventName {
            case "create":
                return .containerCreated
            case "start", "restart", "unpause":
                return .containerStarted
            case "stop", "die", "kill", "pause", "oom":
                return .containerStopped
            case "destroy", "delete", "remove":
                return .containerRemoved
            case "connect", "disconnect", "network_connect", "network_disconnect":
                return .networkChanged
            default:
                return nil
            }
        case "image":
            switch eventName {
            case "pull", "push", "tag", "untag", "delete", "import", "load", "save", "build":
                return .imageChanged
            default:
                return nil
            }
        case "volume":
            switch eventName {
            case "create", "destroy", "remove", "mount", "unmount":
                return .volumeChanged
            default:
                return nil
            }
        case "network":
            return .networkChanged
        default:
            return nil
        }
    }

    public var pulsePayload: [String: String] {
        var payload: [String: String] = [
            "type": objectType,
            "event": eventName
        ]
        if let id, !id.isEmpty {
            payload["id"] = id
        }
        if let actorID {
            payload["actorID"] = actorID
        }
        if let from, !from.isEmpty {
            payload["from"] = from
        }
        if let time {
            payload["time"] = String(time)
        }
        if let timeNano {
            payload["timeNano"] = String(timeNano)
        }
        for key in ["name", "image", "exitCode", "container", "driver"] {
            if let value = actor?.attributes[key], !value.isEmpty {
                payload[key] = value
            }
        }
        return payload
    }

    public static func decode(line data: Data) throws -> ConjetDockerRuntimeEvent {
        try ConjetJSON.decoder().decode(ConjetDockerRuntimeEvent.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "Type"
        case status = "status"
        case action = "Action"
        case id = "id"
        case from = "from"
        case time = "time"
        case timeNano = "timeNano"
        case actor = "Actor"
    }
}

public struct ConjetDockerRuntimeEventActor: Codable, Equatable, Sendable {
    public var id: String?
    public var attributes: [String: String]

    public init(id: String? = nil, attributes: [String: String] = [:]) {
        self.id = id
        self.attributes = attributes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        attributes = try container.decodeIfPresent([String: String].self, forKey: .attributes) ?? [:]
    }

    private enum CodingKeys: String, CodingKey {
        case id = "ID"
        case attributes = "Attributes"
    }
}

public struct ConjetDockerRuntimeObservedEvent: Codable, Equatable, Sendable {
    public var action: String
    public var containerID: String?
    public var publishedPorts: [ConjetPublishedPortRequest]
    public var memoryActivity: String?

    public init(
        action: String,
        containerID: String? = nil,
        publishedPorts: [ConjetPublishedPortRequest] = [],
        memoryActivity: String? = nil
    ) {
        self.action = action
        self.containerID = containerID
        self.publishedPorts = publishedPorts
        self.memoryActivity = memoryActivity
    }
}

public struct ConjetDockerRuntimeObservationSnapshot: Codable, Equatable, Sendable {
    public var containerIDs: [String]
    public var publishedPorts: [ConjetPublishedPortRequest]
    public var dockerActivityEvents: Int
    public var memoryTargetChanges: Int
    public var successfulPortConnections: Int
    public var runtimeEvents: [ConjetDockerRuntimeObservedEvent]

    public init(
        containerIDs: [String] = [],
        publishedPorts: [ConjetPublishedPortRequest] = [],
        dockerActivityEvents: Int = 0,
        memoryTargetChanges: Int = 0,
        successfulPortConnections: Int = 0,
        runtimeEvents: [ConjetDockerRuntimeObservedEvent] = []
    ) {
        self.containerIDs = containerIDs
        self.publishedPorts = publishedPorts
        self.dockerActivityEvents = dockerActivityEvents
        self.memoryTargetChanges = memoryTargetChanges
        self.successfulPortConnections = successfulPortConnections
        self.runtimeEvents = runtimeEvents
    }

    public var portForwardProven: Bool {
        successfulPortConnections > 0 && !publishedPorts.isEmpty
    }

    public var memoryReactionProven: Bool {
        dockerActivityEvents > 0 && memoryTargetChanges > 0
    }
}

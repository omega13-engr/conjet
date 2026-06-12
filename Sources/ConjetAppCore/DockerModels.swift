import Foundation

public struct DockerContainer: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var image: String
    public var command: String
    public var createdAt: String
    public var runningFor: String
    public var ports: String
    public var state: String
    public var status: String
    public var size: String

    private enum CodingKeys: String, CodingKey {
        case id = "ID"
        case name = "Names"
        case image = "Image"
        case command = "Command"
        case createdAt = "CreatedAt"
        case runningFor = "RunningFor"
        case ports = "Ports"
        case state = "State"
        case status = "Status"
        case size = "Size"
    }

    public init(
        id: String,
        name: String,
        image: String,
        command: String = "",
        createdAt: String = "",
        runningFor: String = "",
        ports: String = "",
        state: String,
        status: String,
        size: String = ""
    ) {
        self.id = id
        self.name = name
        self.image = image
        self.command = command
        self.createdAt = createdAt
        self.runningFor = runningFor
        self.ports = ports
        self.state = state
        self.status = status
        self.size = size
    }
}

public struct DockerImage: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var repository: String
    public var tag: String
    public var size: String
    public var createdAt: String
    public var createdSince: String

    private enum CodingKeys: String, CodingKey {
        case id = "ID"
        case repository = "Repository"
        case tag = "Tag"
        case size = "Size"
        case createdAt = "CreatedAt"
        case createdSince = "CreatedSince"
    }

    public var reference: String {
        if repository == "<none>" || tag == "<none>" {
            return id
        }
        return "\(repository):\(tag)"
    }
}

public struct DockerVolume: Identifiable, Codable, Equatable, Sendable {
    public var name: String
    public var driver: String
    public var scope: String
    public var mountpoint: String
    public var labels: String
    public var size: String

    public var id: String { name }

    private enum CodingKeys: String, CodingKey {
        case name = "Name"
        case driver = "Driver"
        case scope = "Scope"
        case mountpoint = "Mountpoint"
        case labels = "Labels"
        case size = "Size"
    }

    public init(
        name: String,
        driver: String,
        scope: String,
        mountpoint: String,
        labels: String,
        size: String = ""
    ) {
        self.name = name
        self.driver = driver
        self.scope = scope
        self.mountpoint = mountpoint
        self.labels = labels
        self.size = size
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.driver = try container.decodeIfPresent(String.self, forKey: .driver) ?? ""
        self.scope = try container.decodeIfPresent(String.self, forKey: .scope) ?? ""
        self.mountpoint = try container.decodeIfPresent(String.self, forKey: .mountpoint) ?? ""
        self.labels = try container.decodeIfPresent(String.self, forKey: .labels) ?? ""
        self.size = try container.decodeIfPresent(String.self, forKey: .size) ?? ""
    }

    public var displaySize: String {
        let trimmed = size.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "N/A" {
            return "-"
        }
        return trimmed
    }
}

struct DockerSystemDiskUsage: Decodable, Equatable, Sendable {
    var volumes: [DockerVolumeUsage]

    private enum CodingKeys: String, CodingKey {
        case volumes = "Volumes"
    }

    static func volumeUsageByName(from output: String) -> [String: DockerVolumeUsage] {
        guard let data = output.data(using: .utf8),
              let usage = try? JSONDecoder().decode(DockerSystemDiskUsage.self, from: data) else {
            return [:]
        }

        return Dictionary(uniqueKeysWithValues: usage.volumes.map { ($0.name, $0) })
    }
}

struct DockerVolumeUsage: Decodable, Equatable, Sendable {
    var name: String
    var size: String

    private enum CodingKeys: String, CodingKey {
        case name = "Name"
        case size = "Size"
    }
}

public struct DockerStats: Identifiable, Codable, Equatable, Sendable {
    public var container: String
    public var name: String
    public var cpuPercent: String
    public var memoryUsage: String
    public var memoryPercent: String
    public var networkIO: String
    public var blockIO: String
    public var pids: String

    public var id: String { container.isEmpty ? name : container }

    private enum CodingKeys: String, CodingKey {
        case container = "Container"
        case name = "Name"
        case cpuPercent = "CPUPerc"
        case memoryUsage = "MemUsage"
        case memoryPercent = "MemPerc"
        case networkIO = "NetIO"
        case blockIO = "BlockIO"
        case pids = "PIDs"
    }
}

public struct ContainerProcess: Identifiable, Equatable, Sendable {
    public var id: String
    public var containerID: String
    public var containerName: String
    public var pid: String
    public var ppid: String
    public var user: String
    public var state: String
    public var command: String

    public init(
        id: String = UUID().uuidString,
        containerID: String,
        containerName: String,
        pid: String,
        ppid: String,
        user: String,
        state: String,
        command: String
    ) {
        self.id = id
        self.containerID = containerID
        self.containerName = containerName
        self.pid = pid
        self.ppid = ppid
        self.user = user
        self.state = state
        self.command = command
    }
}

public enum DockerJSONLines {
    public static func decode<T: Decodable>(_ type: T.Type, from output: String) -> [T] {
        let decoder = JSONDecoder()
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                try? decoder.decode(type, from: Data(line.utf8))
            }
    }
}

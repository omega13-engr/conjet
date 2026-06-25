import Foundation

public enum ContainerGroupKind: Equatable, Sendable {
    case compose(project: String)
    case standalone
}

public enum ContainerGroupReadiness: Equatable, Sendable {
    case ready
    case starting
    case degraded
    case partial
    case stopped
    case empty

    public var displayName: String {
        switch self {
        case .ready: "ready"
        case .starting: "starting"
        case .degraded: "unhealthy"
        case .partial: "partial"
        case .stopped: "stopped"
        case .empty: "empty"
        }
    }

}

public struct ContainerGroup: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var kind: ContainerGroupKind
    public var containers: [DockerContainer]

    public init(
        id: String,
        title: String,
        kind: ContainerGroupKind,
        containers: [DockerContainer]
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.containers = containers
    }

    public var runningCount: Int {
        containers.filter(\.isRunning).count
    }

    public var stoppedCount: Int {
        max(containers.count - runningCount, 0)
    }

    public var healthyCount: Int {
        containers.filter { $0.healthState == .healthy }.count
    }

    public var startingHealthCount: Int {
        containers.filter { $0.healthState == .starting }.count
    }

    public var unhealthyCount: Int {
        containers.filter { $0.healthState == .unhealthy }.count
    }

    public var subtitle: String {
        var parts = ["\(containers.count) containers", "\(runningCount) running"]
        if unhealthyCount > 0 {
            parts.append("\(unhealthyCount) unhealthy")
        } else if startingHealthCount > 0 {
            parts.append("\(startingHealthCount) starting")
        } else if healthyCount > 0 {
            parts.append("\(healthyCount) healthy")
        }
        return parts.joined(separator: " - ")
    }

    public var readiness: ContainerGroupReadiness {
        guard !containers.isEmpty else { return .empty }
        guard runningCount > 0 else { return .stopped }
        if unhealthyCount > 0 { return .degraded }
        if startingHealthCount > 0 { return .starting }
        if runningCount < containers.count { return .partial }
        return .ready
    }

    public var composeProject: String? {
        if case let .compose(project) = kind {
            return project
        }
        return nil
    }

    public var composeWorkingDirectory: String? {
        mostCommon(containers.compactMap(\.composeWorkingDirectory))
    }

    public var composeConfigFiles: [String] {
        mostCommon(containers.map(\.composeConfigFiles).filter { !$0.isEmpty }) ?? []
    }

    public var canRunComposeUp: Bool {
        composeProject != nil && composeWorkingDirectory != nil
    }

    public var startableContainers: [DockerContainer] {
        containers.filter { !$0.isRunning }
    }

    private func mostCommon<T: Hashable>(_ values: [T]) -> T? {
        var counts: [T: Int] = [:]
        for value in values {
            counts[value, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key
    }
}

public enum ContainerGrouping {
    public static func groups(containers: [DockerContainer]) -> [ContainerGroup] {
        let composeBuckets = Dictionary(grouping: containers.compactMap { container -> (String, DockerContainer)? in
            guard let project = container.composeProject else { return nil }
            return (project, container)
        }, by: { $0.0 })

        let groups = composeBuckets.map { project, entries in
            ContainerGroup(
                id: "compose:\(project)",
                title: project,
                kind: .compose(project: project),
                containers: entries.map(\.1).sortedByDisplayName()
            )
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        return groups
    }
}

private extension Array where Element == DockerContainer {
    func sortedByDisplayName() -> [DockerContainer] {
        sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

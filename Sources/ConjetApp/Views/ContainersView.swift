import ConjetAppCore
import SwiftUI

struct ContainersView: View {
    @EnvironmentObject private var app: ConjetAppState
    @State private var searchText = ""
    @State private var selectedPane: ContainerPane = .info

    private var filteredContainers: [DockerContainer] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return app.snapshot.containers }
        return app.snapshot.containers.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.image.localizedCaseInsensitiveContains(query)
                || $0.state.localizedCaseInsensitiveContains(query)
                || $0.status.localizedCaseInsensitiveContains(query)
                || $0.labels.localizedCaseInsensitiveContains(query)
                || ($0.composeProject?.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.composeService?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var selectedContainer: DockerContainer? {
        filteredContainers.first { $0.id == app.selectedContainerID } ?? filteredContainers.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(
                title: "Containers",
                subtitle: "\(app.snapshot.containers.count) total - \(runningCount) running",
                systemImage: "shippingbox"
            )
            Divider()

            ResourceSplitView {
                ContainerMasterPanel(
                    containers: filteredContainers,
                    totalCount: app.snapshot.containers.count,
                    searchText: $searchText,
                    selection: $app.selectedContainerID
                )
            } detail: {
                if let container = selectedContainer {
                    ContainerDetail(container: container, selectedPane: $selectedPane)
                } else {
                    EmptyStateView(
                        systemImage: "shippingbox",
                        title: searchText.isEmpty ? "No Containers" : "No Matching Containers",
                        message: searchText.isEmpty
                            ? "Run an image to create the first managed container."
                            : "Clear the search field to see the full inventory."
                    )
                }
            }
        }
        .background(WorkbenchPalette.contentBackground)
    }

    private var runningCount: Int {
        app.snapshot.containers.filter { $0.state.localizedCaseInsensitiveContains("running") }.count
    }
}

private struct ContainerMasterPanel: View {
    @EnvironmentObject private var app: ConjetAppState

    let containers: [DockerContainer]
    let totalCount: Int
    @Binding var searchText: String
    @Binding var selection: String?

    private var groups: [ContainerGroup] {
        ContainerGrouping.groups(containers: containers)
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Inventory", subtitle: "\(containers.count) shown") {
                IconActionButton(title: "Refresh", systemImage: "arrow.clockwise") {
                    Task { await app.refresh() }
                }
            }
            SearchField(placeholder: "Search containers", text: $searchText)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            Divider()

            if containers.isEmpty {
                EmptyStateView(
                    systemImage: totalCount == 0 ? "shippingbox" : "magnifyingglass",
                    title: totalCount == 0 ? "No Containers" : "No Results",
                    message: totalCount == 0
                        ? "Start a workload from the run panel below."
                        : "Try a different name, image, status, or state."
                )
            } else {
                List(selection: $selection) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.containers) { container in
                                ContainerRow(container: container)
                                    .tag(container.id)
                                    .listRowInsets(EdgeInsets(top: 5, leading: 18, bottom: 5, trailing: 12))
                            }
                        } header: {
                            ContainerGroupHeader(group: group)
                                .textCase(nil)
                                .padding(.top, 4)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }

            Divider()
            RunContainerPanel()
        }
    }
}

private struct ContainerGroupHeader: View {
    @EnvironmentObject private var app: ConjetAppState

    let group: ContainerGroup

    private var isPolling: Bool {
        app.activeContainerGroupID == group.id
    }

    private var primaryAction: (title: String, systemImage: String, action: String) {
        if group.canRunComposeUp {
            return ("Up", "play.fill", "up")
        }
        if group.stoppedCount > 0 {
            return ("Start", "play.fill", "start")
        }
        return ("Restart", "arrow.clockwise", "restart")
    }

    var body: some View {
        HStack(spacing: 9) {
            ResourceIcon(
                systemImage: group.composeProject == nil ? "shippingbox" : "square.stack.3d.up",
                tint: group.readiness.tint,
                size: 24
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(group.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    StatusBadge(text: group.readiness.displayName, state: group.readiness.badgeState)
                }
                Text(group.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if isPolling {
                ProgressView()
                    .controlSize(.small)
                    .help("Polling health status")
            }

            CommandBarButton(title: primaryAction.title, systemImage: primaryAction.systemImage) {
                Task { await app.containerGroupAction(primaryAction.action, group: group) }
            }
            .disabled(group.containers.isEmpty || app.activeCommandLabel != nil)
        }
        .padding(.vertical, 3)
    }
}

private struct RunContainerPanel: View {
    @EnvironmentObject private var app: ConjetAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Run")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField("Image", text: $app.runImage)
                .textFieldStyle(.roundedBorder)
            TextField("Command", text: $app.runCommand)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                CommandBarButton(title: "Run", systemImage: "play.fill") {
                    Task { await app.runContainer() }
                }
                .disabled(app.runImage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(.regularMaterial)
    }
}

private struct ContainerRow: View {
    let container: DockerContainer

    var body: some View {
        HStack(spacing: 10) {
            ResourceIcon(
                systemImage: container.isRunning ? "play.rectangle.fill" : "shippingbox",
                tint: container.isRunning ? .green : .secondary,
                size: 28
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(container.composeService ?? container.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    StatusBadge(text: container.state, state: container.isRunning ? .good : .neutral)
                    if container.healthState != .none {
                        StatusBadge(text: container.healthState.displayName, state: container.healthState.badgeState)
                    }
                }
                Text(container.name == (container.composeService ?? container.name) ? container.image : "\(container.name) - \(container.image)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !container.status.isEmpty {
                    Text(container.status)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

private enum ContainerPane: String, CaseIterable, Identifiable {
    case info = "Info"
    case stats = "Stats"
    case processes = "Processes"

    var id: String { rawValue }
}

private struct ContainerDetail: View {
    @EnvironmentObject private var app: ConjetAppState

    let container: DockerContainer
    @Binding var selectedPane: ContainerPane

    private var isRunning: Bool {
        container.isRunning
    }

    private var matchingStat: DockerStats? {
        app.snapshot.stats.first {
            $0.container == container.id
                || container.id.hasPrefix($0.container)
                || $0.name == container.name
        }
    }

    private var processes: [ContainerProcess] {
        app.snapshot.containerProcesses.filter {
            $0.containerID == container.id
                || container.id.hasPrefix($0.containerID)
                || $0.containerName == container.name
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    ResourceIcon(
                        systemImage: isRunning ? "play.rectangle.fill" : "shippingbox",
                        tint: isRunning ? .green : .secondary,
                        size: 34
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(container.name)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                        Text(container.image)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    StatusBadge(text: container.state, state: isRunning ? .good : .neutral)
                    if container.healthState != .none {
                        StatusBadge(text: container.healthState.displayName, state: container.healthState.badgeState)
                    }
                }

                HStack {
                    CommandBarButton(title: "Start", systemImage: "play.fill") {
                        Task { await app.containerAction("start", container: container) }
                    }
                    CommandBarButton(title: "Stop", systemImage: "stop.fill") {
                        Task { await app.containerAction("stop", container: container) }
                    }
                    CommandBarButton(title: "Restart", systemImage: "arrow.clockwise") {
                        Task { await app.containerAction("restart", container: container) }
                    }
                    Spacer()
                    CommandBarButton(title: "Remove", systemImage: "trash", role: .destructive) {
                        Task { await app.containerAction("remove", container: container) }
                    }
                }

                Picker("Container detail", selection: $selectedPane) {
                    ForEach(ContainerPane.allCases) { pane in
                        Text(pane.rawValue).tag(pane)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch selectedPane {
                case .info:
                    InspectorSection("Info") {
                        KeyValueRows(rows: [
                            ("ID", container.id),
                            ("Image", container.image),
                            ("Command", container.command),
                            ("Status", container.status),
                            ("Health", container.healthState.detailText),
                            ("Compose Project", container.composeProject ?? ""),
                            ("Compose Service", container.composeService ?? ""),
                            ("Ports", container.ports),
                            ("Created", container.createdAt),
                            ("Running For", container.runningFor),
                            ("Size", container.size)
                        ])
                    }
                case .stats:
                    InspectorSection("Stats") {
                        if let matchingStat {
                            KeyValueRows(rows: [
                                ("CPU", matchingStat.cpuPercent),
                                ("Memory", matchingStat.memoryUsage),
                                ("Memory %", matchingStat.memoryPercent),
                                ("Network", matchingStat.networkIO),
                                ("Block I/O", matchingStat.blockIO),
                                ("PIDs", matchingStat.pids)
                            ])
                        } else {
                            EmptyStateView(
                                systemImage: "chart.line.uptrend.xyaxis",
                                title: "No Live Sample",
                                message: "Stats appear when the container is running and Docker returns a sample."
                            )
                            .frame(minHeight: 220)
                        }
                    }
                case .processes:
                    InspectorSection("Processes") {
                        if processes.isEmpty {
                            EmptyStateView(
                                systemImage: "terminal",
                                title: "No Processes",
                                message: "Process rows appear after a running container reports top output."
                            )
                            .frame(minHeight: 220)
                        } else {
                            ProcessRows(processes: processes)
                        }
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

private extension ContainerGroupReadiness {
    var badgeState: StatusBadge.BadgeState {
        switch self {
        case .ready: .good
        case .starting, .partial: .warning
        case .degraded: .bad
        case .stopped, .empty: .neutral
        }
    }

    var tint: Color {
        switch self {
        case .ready: .green
        case .starting, .partial: .orange
        case .degraded: .red
        case .stopped, .empty: .secondary
        }
    }
}

private extension DockerContainerHealthState {
    var displayName: String {
        switch self {
        case .healthy: "healthy"
        case .starting: "starting"
        case .unhealthy: "unhealthy"
        case .none: "no healthcheck"
        }
    }

    var detailText: String {
        switch self {
        case .none: ""
        default: displayName
        }
    }

    var badgeState: StatusBadge.BadgeState {
        switch self {
        case .healthy: .good
        case .starting: .warning
        case .unhealthy: .bad
        case .none: .neutral
        }
    }
}

private struct ProcessRows: View {
    let processes: [ContainerProcess]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("PID").frame(width: 70, alignment: .leading)
                Text("User").frame(width: 90, alignment: .leading)
                Text("State").frame(width: 64, alignment: .leading)
                Text("Command").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)

            Divider()

            ForEach(processes) { process in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(process.pid).frame(width: 70, alignment: .leading)
                    Text(process.user).frame(width: 90, alignment: .leading)
                    Text(process.state).frame(width: 64, alignment: .leading)
                    Text(process.command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
                .padding(.vertical, 7)
                Divider()
            }
        }
    }
}

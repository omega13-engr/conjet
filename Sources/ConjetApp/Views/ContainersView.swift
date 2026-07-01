import ConjetAppCore
import SwiftUI

struct ContainersView: View {
    @EnvironmentObject private var app: ConjetAppState
    @State private var searchText = ""
    @State private var selectedPane: ContainerPane = .info

    init(showTerminal: Bool = false) {
        _selectedPane = State(initialValue: showTerminal ? .terminal : .info)
    }

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
    @AppStorage("containers.collapsedComposeGroupIDs") private var collapsedComposeGroupIDs = ""
    private let composeChildIndent: CGFloat = 36

    let containers: [DockerContainer]
    let totalCount: Int
    @Binding var searchText: String
    @Binding var selection: String?

    private var composeGroups: [ContainerGroup] {
        ContainerGrouping.groups(containers: containers)
    }

    private var standaloneContainers: [DockerContainer] {
        containers
            .filter { $0.composeProject == nil }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private var collapsedGroupIDs: Set<String> {
        Set(collapsedComposeGroupIDs.split(separator: "\n").map(String.init))
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
                        ? "Build a workload from the Dockerfile editor below."
                        : "Try a different name, image, status, or state."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(composeGroups) { group in
                            let collapsed = isCollapsed(group)
                            VStack(spacing: 0) {
                                ContainerGroupRow(
                                    group: group,
                                    isCollapsed: collapsed
                                ) {
                                    toggleGroup(group)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)

                                if !collapsed {
                                    ForEach(group.containers) { container in
                                        ContainerSelectableRow(container: container, selection: $selection)
                                            .padding(.leading, 12 + composeChildIndent)
                                            .padding(.trailing, 12)
                                            .padding(.vertical, 3)
                                    }
                                }
                            }

                            Divider()
                                .padding(.leading, 54)
                        }

                        ForEach(standaloneContainers) { container in
                            ContainerSelectableRow(container: container, selection: $selection)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 3)
                            Divider()
                                .padding(.leading, 54)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }

            Divider()
            ContainerDockerEditorPanel()
        }
    }

    private func isCollapsed(_ group: ContainerGroup) -> Bool {
        collapsedGroupIDs.contains(group.id)
    }

    private func toggleGroup(_ group: ContainerGroup) {
        var ids = collapsedGroupIDs
        if ids.contains(group.id) {
            ids.remove(group.id)
        } else {
            ids.insert(group.id)
        }
        collapsedComposeGroupIDs = ids.sorted().joined(separator: "\n")
    }
}

private struct ContainerGroupRow: View {
    @EnvironmentObject private var app: ConjetAppState

    let group: ContainerGroup
    let isCollapsed: Bool
    let toggle: () -> Void

    private var hasRunningComposeContainers: Bool {
        group.canRunComposeUp && group.runningCount > 0
    }

    private var actionsDisabled: Bool {
        group.containers.isEmpty || app.activeCommandLabel != nil
    }

    private var lifecycleAction: LifecycleCommand {
        if group.canRunComposeUp {
            if group.runningCount > 0 {
                return LifecycleCommand(title: "Down", systemImage: "arrow.down.circle", action: "down", role: .destructive)
            }
            return LifecycleCommand(title: "Up", systemImage: "play.fill", action: "up")
        }
        if group.runningCount > 0 {
            return LifecycleCommand(title: "Stop", systemImage: "stop.fill", action: "stop", role: .destructive)
        }
        return LifecycleCommand(title: "Start", systemImage: "play.fill", action: "start")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 10)
                    ResourceIcon(
                        systemImage: "square.stack.3d.up",
                        tint: group.readiness.tint,
                        size: 24
                    )
                }
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Expand compose group" : "Collapse compose group")

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .center, spacing: 8) {
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

                    if !hasRunningComposeContainers {
                        lifecycleButton
                    }
                }

                if hasRunningComposeContainers {
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        CommandBarButton(title: "Restart", systemImage: "arrow.clockwise") {
                            Task { await app.containerGroupAction("restart", group: group) }
                        }
                        .disabled(actionsDisabled)
                        lifecycleButton
                        CommandBarButton(title: "Stop", systemImage: "stop.fill", role: .destructive) {
                            Task { await app.containerGroupAction("stop", group: group) }
                        }
                        .disabled(actionsDisabled)
                    }
                }
            }
        }
        .padding(.vertical, 5)
    }

    private var lifecycleButton: some View {
        CommandBarButton(
            title: lifecycleAction.title,
            systemImage: lifecycleAction.systemImage,
            role: lifecycleAction.role
        ) {
            Task { await app.containerGroupAction(lifecycleAction.action, group: group) }
        }
        .disabled(actionsDisabled)
    }
}

private struct ContainerRow: View {
    let container: DockerContainer
    var isSelected = false

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
                        .foregroundStyle(isSelected ? .white : .primary)
                        .lineLimit(1)
                    StatusBadge(text: container.state, state: container.isRunning ? .good : .neutral)
                    if container.healthState != .none {
                        StatusBadge(text: container.healthState.displayName, state: container.healthState.badgeState)
                    }
                }
                Text(container.name == (container.composeService ?? container.name) ? container.image : "\(container.name) - \(container.image)")
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white.opacity(0.78) : .secondary)
                    .lineLimit(1)
                if !container.status.isEmpty {
                    Text(container.status)
                        .font(.caption2)
                        .foregroundStyle(isSelected ? .white.opacity(0.58) : .secondary.opacity(0.65))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

private struct ContainerSelectableRow: View {
    let container: DockerContainer
    @Binding var selection: String?

    private var isSelected: Bool {
        selection == container.id
    }

    var body: some View {
        Button {
            selection = container.id
        } label: {
            ContainerRow(container: container, isSelected: isSelected)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor)
            }
        }
        .accessibilityLabel(container.name)
    }
}

private enum ContainerPane: String, CaseIterable, Identifiable {
    case info = "Info"
    case stats = "Stats"
    case processes = "Processes"
    case terminal = "Terminal"

    var id: String { rawValue }
}

private struct ContainerDetail: View {
    @EnvironmentObject private var app: ConjetAppState

    let container: DockerContainer
    @Binding var selectedPane: ContainerPane

    private var isRunning: Bool {
        container.isRunning
    }

    private var lifecycleAction: LifecycleCommand {
        if isRunning {
            return LifecycleCommand(title: "Stop", systemImage: "stop.fill", action: "stop", role: .destructive)
        }
        return LifecycleCommand(title: "Start", systemImage: "play.fill", action: "start")
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
        if selectedPane == .terminal {
            VStack(alignment: .leading, spacing: 14) {
                containerHeader
                containerActions
                paneSelector
                ContainerTerminalPane(container: container)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    containerHeader
                    containerActions
                    paneSelector
                    selectedPaneContent
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var containerHeader: some View {
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
    }

    private var containerActions: some View {
        HStack {
            CommandBarButton(
                title: lifecycleAction.title,
                systemImage: lifecycleAction.systemImage,
                role: lifecycleAction.role
            ) {
                Task { await app.containerAction(lifecycleAction.action, container: container) }
            }
            .disabled(app.activeCommandLabel != nil)
            CommandBarButton(title: "Restart", systemImage: "arrow.clockwise") {
                Task { await app.containerAction("restart", container: container) }
            }
            Spacer()
            CommandBarButton(title: "Remove", systemImage: "trash", role: .destructive) {
                Task { await app.containerAction("remove", container: container) }
            }
        }
    }

    private var paneSelector: some View {
        HStack(alignment: .center, spacing: 12) {
            Picker("Container detail", selection: $selectedPane) {
                ForEach(ContainerPane.allCases) { pane in
                    Text(pane.rawValue).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)

            if selectedPane == .terminal {
                Toggle(isOn: $app.containerTerminalDebugEnabled) {
                    Label("Debug exec", systemImage: "ladybug")
                }
                .toggleStyle(.checkbox)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityLabel("Enable Docker debug mode for terminal exec")
            }
        }
    }

    @ViewBuilder
    private var selectedPaneContent: some View {
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
        case .terminal:
            ContainerTerminalPane(container: container)
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

private struct ContainerTerminalPane: View {
    @EnvironmentObject private var app: ConjetAppState

    let container: DockerContainer
    @State private var terminalCommand: DockerTerminalCommand?
    @State private var terminalSessionID = UUID()
    @State private var terminalError: String?

    var body: some View {
        ZStack {
            if let terminalCommand {
                ContainerTerminalView(command: terminalCommand)
                    .id(terminalSessionID)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.72))
                Text(terminalError ?? (container.isRunning ? "Starting shell..." : "Container stopped"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(WorkbenchPalette.border)
        }
        .onAppear {
            startTerminal()
        }
        .onChange(of: app.containerTerminalDebugEnabled) { _, _ in
            restartTerminal()
        }
        .onChange(of: container.id) { _, _ in
            restartTerminal()
        }
    }

    private func startTerminal() {
        guard terminalCommand?.containerID != container.id else { return }
        guard container.isRunning else {
            terminalError = "Container stopped"
            return
        }
        guard let command = app.prepareContainerTerminal(container: container) else {
            terminalError = app.containerTerminalError ?? "Unable to start shell"
            return
        }
        terminalError = nil
        terminalCommand = command
        terminalSessionID = UUID()
    }

    private func restartTerminal() {
        terminalCommand = nil
        terminalError = nil
        startTerminal()
    }
}

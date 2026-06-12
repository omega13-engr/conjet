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
                    ForEach(containers) { container in
                        ContainerRow(container: container)
                            .tag(container.id)
                            .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
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

    private var isRunning: Bool {
        container.state.localizedCaseInsensitiveContains("running")
    }

    var body: some View {
        HStack(spacing: 10) {
            ResourceIcon(
                systemImage: isRunning ? "play.rectangle.fill" : "shippingbox",
                tint: isRunning ? .green : .secondary,
                size: 28
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(container.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    StatusBadge(text: container.state, state: isRunning ? .good : .neutral)
                }
                Text(container.image)
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
        container.state.localizedCaseInsensitiveContains("running")
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

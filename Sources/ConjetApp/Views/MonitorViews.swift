import ConjetAppCore
import ConjetCore
import SwiftUI

struct ActivityMonitorView: View {
    @EnvironmentObject private var app: ConjetAppState

    var body: some View {
        let activity = app.snapshot.containerActivity

        VStack(spacing: 0) {
            HeaderView(title: "Activity Monitor", subtitle: "Live container workload telemetry", systemImage: "waveform.path.ecg")
            Divider()

            VStack(spacing: 14) {
                ActivityStatsTable(stats: app.snapshot.stats)
                    .frame(maxHeight: .infinity)

                HStack(spacing: 10) {
                    MetricCard(
                        title: "CPU",
                        value: activity.totalCPUPercentText,
                        detail: activity.busiestContainerText,
                        systemImage: "cpu",
                        tint: .blue
                    )
                    MetricCard(
                        title: "Memory Samples",
                        value: "\(activity.statsSampleCount)",
                        detail: "\(activity.runningContainers) running containers",
                        systemImage: "memorychip",
                        tint: .green
                    )
                    MetricCard(
                        title: "Processes",
                        value: "\(activity.processCount)",
                        detail: "\(activity.totalContainers) tracked containers",
                        systemImage: "terminal",
                        tint: .purple
                    )
                    MetricCard(
                        title: "Stopped",
                        value: "\(activity.stoppedContainers)",
                        detail: "container inventory",
                        systemImage: "pause.circle",
                        tint: .orange
                    )
                }
            }
            .padding(16)
            .background(WorkbenchPalette.contentBackground)
        }
    }
}

private struct ActivityStatsTable: View {
    let stats: [DockerStats]

    var body: some View {
        AppCard {
            VStack(spacing: 0) {
                HStack {
                    Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                    Text("CPU %").frame(width: 82, alignment: .trailing)
                    Text("Memory").frame(width: 170, alignment: .trailing)
                    Text("Network").frame(width: 150, alignment: .trailing)
                    Text("PIDs").frame(width: 70, alignment: .trailing)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

                Divider()

                if stats.isEmpty {
                    EmptyStateView(
                        systemImage: "waveform.path.ecg",
                        title: "No Running Container Stats",
                        message: "Telemetry appears here after Docker returns live container samples."
                    )
                    .frame(minHeight: 320)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(stats) { stat in
                                ActivityStatRow(stat: stat)
                                Divider()
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
    }
}

private struct ActivityStatRow: View {
    let stat: DockerStats

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(stat.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(stat.cpuPercent)
                .monospacedDigit()
                .frame(width: 82, alignment: .trailing)
            Text(stat.memoryUsage)
                .lineLimit(1)
                .frame(width: 170, alignment: .trailing)
            Text(stat.networkIO)
                .lineLimit(1)
                .frame(width: 150, alignment: .trailing)
            Text(stat.pids)
                .monospacedDigit()
                .frame(width: 70, alignment: .trailing)
        }
        .font(.callout)
        .padding(.vertical, 8)
    }
}

struct NetworkMonitorView: View {
    @EnvironmentObject private var app: ConjetAppState
    @State private var selectedNetworkID: String?

    var body: some View {
        let network = app.snapshot.network
        let dockerNetworks = app.snapshot.dockerNetworks.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let selectedDockerNetwork = dockerNetworks.first { $0.id == selectedNetworkID }
            ?? dockerNetworks.first

        VStack(spacing: 0) {
            HeaderView(title: "Network", subtitle: network?.bridgeEngine ?? "Bridge status unavailable", systemImage: "network")
            Divider()

            ResourceSplitView {
                VStack(spacing: 0) {
                    PanelHeader(title: "Docker Networks", subtitle: "\(dockerNetworks.count) total")
                    Divider()
                    if dockerNetworks.isEmpty {
                        EmptyStateView(
                            systemImage: "point.3.connected.trianglepath.dotted",
                            title: "No Docker Networks",
                            message: "Docker networks will appear after the Conjet Docker socket is reachable."
                        )
                    } else {
                        List(selection: $selectedNetworkID) {
                            ForEach(dockerNetworks) { dockerNetwork in
                                NetworkRow(
                                    title: dockerNetwork.name,
                                    subtitle: dockerNetwork.detailText.isEmpty ? dockerNetwork.id : dockerNetwork.detailText,
                                    tint: dockerNetwork.driver == "bridge" ? .teal : .blue
                                )
                                .tag(dockerNetwork.id)
                                .listRowInsets(EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12))
                            }
                        }
                        .listStyle(.inset)
                        .scrollContentBackground(.hidden)
                    }
                }
            } detail: {
                NetworkDetail(network: network, dockerNetwork: selectedDockerNetwork)
            }
        }
        .background(WorkbenchPalette.contentBackground)
    }
}

private struct NetworkRow: View {
    let title: String
    let subtitle: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            ResourceIcon(systemImage: "point.3.connected.trianglepath.dotted", tint: tint, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct NetworkDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct NetworkDetail: View {
    @EnvironmentObject private var app: ConjetAppState
    let network: ConjetNetworkStatus?
    let dockerNetwork: DockerNetwork?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ResourceIcon(systemImage: "network", tint: .teal, size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("bridge")
                            .font(.title3.weight(.semibold))
                        Text(network?.bridgeEngine ?? "No active bridge engine")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusBadge(
                        text: network?.eventWatcherState ?? "unknown",
                        state: network?.failedForwards == 0 ? .good : .warning
                    )
                }

                if let dockerNetwork {
                    InspectorSection("Docker Network") {
                        VStack(alignment: .leading, spacing: 8) {
                            NetworkDetailRow(label: "Name", value: dockerNetwork.name)
                            NetworkDetailRow(label: "ID", value: dockerNetwork.id)
                            NetworkDetailRow(label: "Driver", value: dockerNetwork.driver.isEmpty ? "-" : dockerNetwork.driver)
                            NetworkDetailRow(label: "Scope", value: dockerNetwork.scope.isEmpty ? "-" : dockerNetwork.scope)
                            NetworkDetailRow(label: "IPv6", value: dockerNetwork.ipv6.isEmpty ? "-" : dockerNetwork.ipv6)
                            NetworkDetailRow(label: "Internal", value: dockerNetwork.internalNetwork.isEmpty ? "-" : dockerNetwork.internalNetwork)
                        }
                    }
                }

                InspectorSection("Policy") {
                    HStack(alignment: .center, spacing: 10) {
                        Picker("Bind", selection: $app.selectedBindPolicy) {
                            ForEach(ConjetNetworkBindPolicy.allCases, id: \.self) { policy in
                                Text(policy.rawValue).tag(policy)
                            }
                        }
                        Picker("Bridge", selection: $app.selectedBridgeEngine) {
                            ForEach(ConjetNetworkBridgeEngine.allCases, id: \.self) { engine in
                                Text(engine.rawValue).tag(engine)
                            }
                        }
                        Spacer()
                        CommandBarButton(title: "Apply", systemImage: "checkmark.circle") {
                            Task { await app.applyNetworkPolicy() }
                        }
                        CommandBarButton(title: "Repair", systemImage: "wrench.adjustable") {
                            Task { await app.repairNetwork() }
                        }
                        CommandBarButton(title: "Test", systemImage: "testtube.2") {
                            Task { await app.bridgeTest() }
                        }
                    }
                    .controlSize(.small)
                }

                HStack(spacing: 10) {
                    MetricCard(
                        title: "TCP Forwards",
                        value: "\(network?.activeTCPForwards ?? 0)",
                        detail: network?.tcpMode ?? "unknown",
                        systemImage: "arrow.left.arrow.right",
                        tint: .blue
                    )
                    MetricCard(
                        title: "UDP Forwards",
                        value: "\(network?.activeUDPForwards ?? 0)",
                        detail: network?.udpMode ?? "unknown",
                        systemImage: "dot.radiowaves.left.and.right",
                        tint: .teal
                    )
                    MetricCard(
                        title: "Conflicts",
                        value: "\(network?.conflictCount ?? 0)",
                        detail: "\(network?.failedForwards ?? 0) failed forwards",
                        systemImage: "exclamationmark.triangle",
                        tint: .orange
                    )
                }

                InspectorSection("Published Ports") {
                    if let forwards = network?.forwards, !forwards.isEmpty {
                        PortForwardRows(forwards: forwards.sorted { $0.hostPort < $1.hostPort })
                    } else {
                        EmptyStateView(
                            systemImage: "arrow.left.arrow.right",
                            title: "No Published Ports",
                            message: "Published TCP or UDP endpoints will appear here when containers expose ports."
                        )
                        .frame(minHeight: 220)
                    }
                }

                InspectorSection("Messages") {
                    let messages = Array(network?.messages.suffix(12) ?? [])
                    if messages.isEmpty {
                        Text("No messages")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(messages), id: \.self) { message in
                                Text(message)
                                    .font(.callout)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

private struct PortForwardRows: View {
    let forwards: [ConjetPortForwardStatus]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Port").frame(width: 72, alignment: .leading)
                Text("Protocol").frame(width: 82, alignment: .leading)
                Text("Bind").frame(maxWidth: .infinity, alignment: .leading)
                Text("State").frame(width: 110, alignment: .leading)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)

            Divider()

            ForEach(Array(forwards.enumerated()), id: \.offset) { _, forward in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(forward.hostPort)")
                        .monospacedDigit()
                        .frame(width: 72, alignment: .leading)
                    Text(forward.protocol.rawValue)
                        .frame(width: 82, alignment: .leading)
                    Text("\(forward.hostIP) -> \(forward.targetIP ?? "unknown"):\(forward.targetPort)")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    StatusBadge(
                        text: forward.state.rawValue,
                        state: forward.state == .listening ? .good : .warning
                    )
                    .frame(width: 110, alignment: .leading)
                }
                .font(.callout)
                .padding(.vertical, 7)
                Divider()
            }
        }
    }
}

struct ProcessCommandsView: View {
    @EnvironmentObject private var app: ConjetAppState

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(
                title: "Processes",
                subtitle: "\(app.snapshot.containerProcesses.count) container processes",
                systemImage: "terminal"
            )
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    InspectorSection("Container Process Table") {
                        ContainerProcessActivityGrid(processes: app.snapshot.containerProcesses)
                    }

                    InspectorSection("Command Audit") {
                        let latest = app.commandLog.prefix(8)
                        if latest.isEmpty {
                            Text("No commands executed from the app")
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(latest)) { entry in
                                    CommandLogRow(entry: entry)
                                }
                            }
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(WorkbenchPalette.contentBackground)
        }
    }
}

struct CommandLogView: View {
    @EnvironmentObject private var app: ConjetAppState
    @State private var selectedCommandID: CommandLogEntry.ID?

    private var selectedEntry: CommandLogEntry? {
        app.commandLog.first { $0.id == selectedCommandID } ?? app.commandLog.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(title: "Commands", subtitle: "\(app.commandLog.count) recorded", systemImage: "list.bullet.rectangle") {
                IconActionButton(title: "Clear command log", systemImage: "trash", role: .destructive) {
                    app.clearCommandLog()
                    selectedCommandID = nil
                }
                .disabled(app.commandLog.isEmpty)
            }
            Divider()

            ResourceSplitView {
                VStack(spacing: 0) {
                    PanelHeader(title: "Command Log", subtitle: "\(app.commandLog.count) entries")
                    Divider()
                    if app.commandLog.isEmpty {
                        EmptyStateView(
                            systemImage: "list.bullet.rectangle",
                            title: "No Commands",
                            message: "Commands executed from Conjet will appear here."
                        )
                    } else {
                        List(selection: $selectedCommandID) {
                            ForEach(app.commandLog) { entry in
                                CommandLogRow(entry: entry)
                                    .tag(entry.id)
                                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            }
                        }
                        .listStyle(.inset)
                        .scrollContentBackground(.hidden)
                    }
                }
            } detail: {
                if let entry = selectedEntry {
                    CommandDetail(entry: entry)
                } else {
                    EmptyStateView(
                        systemImage: "list.bullet.rectangle",
                        title: "No Selection",
                        message: "Select a command to inspect its output."
                    )
                }
            }
        }
        .background(WorkbenchPalette.contentBackground)
    }
}

private struct CommandDetail: View {
    let entry: CommandLogEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ResourceIcon(
                        systemImage: entry.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill",
                        tint: entry.succeeded ? .green : .red,
                        size: 34
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.label)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                        Text(ConjetAppFormatters.shortDateTime.string(from: entry.startedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusBadge(text: entry.succeeded ? "success" : "failed", state: entry.succeeded ? .good : .bad)
                }

                InspectorSection("Info") {
                    KeyValueRows(rows: [
                        ("Command", entry.commandLine),
                        ("Exit", String(entry.exitCode)),
                        ("Started", ConjetAppFormatters.shortDateTime.string(from: entry.startedAt)),
                        ("Duration", String(format: "%.2fs", entry.duration))
                    ])
                }

                InspectorSection("Output") {
                    OutputBlock(text: [entry.stdout, entry.stderr].filter { !$0.isEmpty }.joined(separator: "\n"))
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

private struct CommandLogRow: View {
    let entry: CommandLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(entry.label, systemImage: entry.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(entry.succeeded ? .green : .red)
                    .lineLimit(1)
                Spacer()
                Text(ConjetAppFormatters.timestamp.string(from: entry.finishedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(entry.commandLine)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

private struct ContainerProcessActivityGrid: View {
    let processes: [ContainerProcess]

    var body: some View {
        if processes.isEmpty {
            EmptyStateView(
                systemImage: "terminal",
                title: "No Container Processes",
                message: "Process samples appear when running containers report command activity."
            )
            .frame(minHeight: 260)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("Container").frame(maxWidth: .infinity, alignment: .leading)
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
                        Text(process.containerName)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(process.pid).frame(width: 70, alignment: .leading)
                        Text(process.user).frame(width: 90, alignment: .leading)
                        Text(process.state).frame(width: 64, alignment: .leading)
                        Text(process.command)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout)
                    .padding(.vertical, 7)
                    Divider()
                }
            }
        }
    }
}

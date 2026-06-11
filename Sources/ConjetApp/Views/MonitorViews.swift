import ConjetAppCore
import ConjetCore
import SwiftUI

struct ActivityMonitorView: View {
    @EnvironmentObject private var app: ConjetAppState

    var body: some View {
        let activity = app.snapshot.containerActivity
        VStack(alignment: .leading, spacing: 16) {
            HeaderView(title: "Activity Monitor", subtitle: "All container activity", systemImage: "waveform.path.ecg")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                MetricCard(title: "Running", value: "\(activity.runningContainers)", detail: "\(activity.totalContainers) total", systemImage: "shippingbox.fill", tint: .green)
                MetricCard(title: "Stopped", value: "\(activity.stoppedContainers)", detail: "container inventory", systemImage: "pause.circle", tint: .orange)
                MetricCard(title: "Container CPU", value: activity.totalCPUPercentText, detail: activity.busiestContainerText, systemImage: "cpu", tint: .blue)
                MetricCard(title: "Processes", value: "\(activity.processCount)", detail: "\(activity.statsSampleCount) stats samples", systemImage: "terminal", tint: .purple)
            }

            AppCard("Container stats") {
                if app.snapshot.stats.isEmpty {
                    Text("No running container stats")
                        .foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        GridRow {
                            Text("Name").foregroundStyle(.secondary)
                            Text("CPU").foregroundStyle(.secondary)
                            Text("Memory").foregroundStyle(.secondary)
                            Text("Network").foregroundStyle(.secondary)
                            Text("PIDs").foregroundStyle(.secondary)
                        }
                        Divider()
                        ForEach(app.snapshot.stats) { stat in
                            GridRow {
                                Text(stat.name).lineLimit(1)
                                Text(stat.cpuPercent)
                                Text(stat.memoryUsage).lineLimit(1)
                                Text(stat.networkIO).lineLimit(1)
                                Text(stat.pids)
                            }
                        }
                    }
                    .font(.callout)
                }
            }

            AppCard("Container process activity") {
                ContainerProcessActivityGrid(processes: app.snapshot.containerProcesses)
            }
        }
        .page()
    }
}

struct NetworkMonitorView: View {
    @EnvironmentObject private var app: ConjetAppState

    var body: some View {
        let network = app.snapshot.daemonResponse?.status?.network
        VStack(alignment: .leading, spacing: 16) {
            HeaderView(title: "Network Monitor", subtitle: network?.bridgeEngine, systemImage: "network")

            AppCard("Policy") {
                HStack {
                    Picker("Bind policy", selection: $app.selectedBindPolicy) {
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
                    CommandBarButton(title: "Bridge Test", systemImage: "testtube.2") {
                        Task { await app.bridgeTest() }
                    }
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                MetricCard(title: "TCP Forwards", value: "\(network?.activeTCPForwards ?? 0)", detail: network?.tcpMode ?? "unknown", systemImage: "point.3.connected.trianglepath.dotted", tint: .blue)
                MetricCard(title: "UDP Forwards", value: "\(network?.activeUDPForwards ?? 0)", detail: network?.udpMode ?? "unknown", systemImage: "dot.radiowaves.left.and.right", tint: .teal)
                MetricCard(title: "Conflicts", value: "\(network?.conflictCount ?? 0)", detail: "\(network?.failedForwards ?? 0) failed", systemImage: "exclamationmark.triangle", tint: .orange)
                MetricCard(title: "Events", value: network?.eventWatcherState ?? "unknown", detail: network?.targetEventWatcherState ?? "target unknown", systemImage: "antenna.radiowaves.left.and.right", tint: .purple)
            }

            AppCard("Published ports") {
                if let forwards = network?.forwards, !forwards.isEmpty {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                        GridRow {
                            Text("Port").foregroundStyle(.secondary)
                            Text("Protocol").foregroundStyle(.secondary)
                            Text("Bind").foregroundStyle(.secondary)
                            Text("Target").foregroundStyle(.secondary)
                            Text("State").foregroundStyle(.secondary)
                            Text("Container").foregroundStyle(.secondary)
                        }
                        Divider()
                        ForEach(forwards.sorted { $0.hostPort < $1.hostPort }, id: \.hostPort) { forward in
                            GridRow {
                                Text("\(forward.hostPort)")
                                Text(forward.protocol.rawValue)
                                Text(forward.hostIP)
                                Text("\(forward.targetIP ?? "unknown"):\(forward.targetPort)")
                                StatusBadge(text: forward.state.rawValue, state: forward.state == .listening ? .good : .warning)
                                Text(forward.containerName ?? String((forward.containerID ?? "-").prefix(12)))
                            }
                        }
                    }
                    .font(.callout)
                } else {
                    Text("No published ports")
                        .foregroundStyle(.secondary)
                }
            }

            AppCard("Messages") {
                let messages = network?.messages.suffix(12) ?? []
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
        .page()
    }
}

struct ProcessCommandsView: View {
    @EnvironmentObject private var app: ConjetAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HeaderView(title: "Process Commands", subtitle: "\(app.snapshot.containerProcesses.count) container processes", systemImage: "terminal")

            AppCard("Container process table") {
                if app.snapshot.containerProcesses.isEmpty {
                    Text("No container processes")
                        .foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                        GridRow {
                            Text("Container").foregroundStyle(.secondary)
                            Text("PID").foregroundStyle(.secondary)
                            Text("User").foregroundStyle(.secondary)
                            Text("State").foregroundStyle(.secondary)
                            Text("Command").foregroundStyle(.secondary)
                        }
                        Divider()
                        ForEach(app.snapshot.containerProcesses) { process in
                            GridRow {
                                Text(process.containerName).lineLimit(1)
                                Text(process.pid)
                                Text(process.user)
                                Text(process.state)
                                Text(process.command).lineLimit(2).textSelection(.enabled)
                            }
                        }
                    }
                    .font(.callout)
                }
            }

            AppCard("Command audit") {
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
        .page()
    }
}

struct CommandLogView: View {
    @EnvironmentObject private var app: ConjetAppState
    @State private var selectedCommandID: CommandLogEntry.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HeaderView(title: "Commands", subtitle: "\(app.commandLog.count) recorded", systemImage: "list.bullet.rectangle")
            HStack {
                Spacer()
                Button(role: .destructive) {
                    app.clearCommandLog()
                    selectedCommandID = nil
                } label: {
                    Label("Clear", systemImage: "trash")
                }
            }
            HSplitView {
                List(selection: $selectedCommandID) {
                    ForEach(app.commandLog) { entry in
                        CommandLogRow(entry: entry)
                            .tag(entry.id)
                    }
                }
                .frame(minWidth: 380)

                if let entry = app.commandLog.first(where: { $0.id == selectedCommandID }) ?? app.commandLog.first {
                    AppCard(entry.label) {
                        KeyValueRows(rows: [
                            ("command", entry.commandLine),
                            ("exit", String(entry.exitCode)),
                            ("started", ConjetAppFormatters.shortDateTime.string(from: entry.startedAt)),
                            ("duration", String(format: "%.2fs", entry.duration))
                        ])
                        OutputBlock(text: [entry.stdout, entry.stderr].filter { !$0.isEmpty }.joined(separator: "\n"))
                    }
                    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    AppCard { Text("No commands").foregroundStyle(.secondary) }
                }
            }
            .frame(minHeight: 520)
        }
        .page()
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
        .padding(.vertical, 4)
    }
}

private struct ContainerProcessActivityGrid: View {
    let processes: [ContainerProcess]

    var body: some View {
        if processes.isEmpty {
            Text("No container process sample")
                .foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("Container").foregroundStyle(.secondary)
                    Text("PID").foregroundStyle(.secondary)
                    Text("User").foregroundStyle(.secondary)
                    Text("State").foregroundStyle(.secondary)
                    Text("Command").foregroundStyle(.secondary)
                }
                Divider()
                ForEach(processes) { process in
                    GridRow {
                        Text(process.containerName).lineLimit(1)
                        Text(process.pid)
                        Text(process.user)
                        Text(process.state)
                        Text(process.command)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
            }
            .font(.callout)
        }
    }
}

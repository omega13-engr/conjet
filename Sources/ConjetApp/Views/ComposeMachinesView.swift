import SwiftUI

struct ComposeView: View {
    @EnvironmentObject private var app: ConjetAppState

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(title: "Compose", subtitle: app.composeDirectory, systemImage: "square.stack.3d.up")
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    AppCard("Project") {
                        TextField("Directory", text: $app.composeDirectory)
                            .textFieldStyle(.roundedBorder)
                        TextField("Up arguments", text: $app.composeArguments)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            CommandBarButton(title: "Up", systemImage: "play.fill") { Task { await app.compose("up") } }
                            CommandBarButton(title: "Down", systemImage: "stop.fill") { Task { await app.compose("down") } }
                            CommandBarButton(title: "PS", systemImage: "list.bullet") { Task { await app.compose("ps") } }
                            CommandBarButton(title: "Logs", systemImage: "doc.text.magnifyingglass") { Task { await app.compose("logs") } }
                            Spacer()
                        }
                    }

                    AppCard("Recent Compose Output") {
                        if let entry = app.commandLog.first(where: { $0.label.hasPrefix("Compose") }) {
                            OutputBlock(text: [entry.stdout, entry.stderr].filter { !$0.isEmpty }.joined(separator: "\n"))
                        } else {
                            EmptyStateView(
                                systemImage: "doc.text.magnifyingglass",
                                title: "No Compose Commands",
                                message: "Run a Compose action to inspect the latest output here."
                            )
                            .frame(minHeight: 260)
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

struct MachinesView: View {
    @EnvironmentObject private var app: ConjetAppState

    var body: some View {
        let vm = app.displayedVMStatus

        VStack(spacing: 0) {
            HeaderView(title: "Machines", subtitle: vm?.message, systemImage: "desktopcomputer")
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if vm == nil {
                        EmptyStateView(
                            systemImage: "desktopcomputer",
                            title: "No Machine Status",
                            message: "Start or query the runtime VM to populate machine details."
                        ) {
                            CommandBarButton(title: "Start Machine", systemImage: "play.fill") {
                                Task { await app.vm("start") }
                            }
                        }
                        .frame(minHeight: 320)
                    }

                    AppCard("Runtime VM") {
                        HStack {
                            StatusBadge(
                                text: vm?.state.rawValue ?? "unknown",
                                state: vm?.state == .running ? .good : .neutral
                            )
                            Spacer()
                            CommandBarButton(title: "Start", systemImage: "play.fill") { Task { await app.vm("start") } }
                            CommandBarButton(title: "Stop", systemImage: "stop.fill") { Task { await app.vm("stop") } }
                            CommandBarButton(title: "Logs", systemImage: "doc.text") { Task { await app.vm("logs") } }
                            CommandBarButton(title: "Fetch Core", systemImage: "arrow.down.circle") { Task { await app.vm("fetchCore") } }
                        }
                        KeyValueRows(rows: [
                            ("Configured", (vm?.configured ?? false) ? "yes" : "no"),
                            ("Manifest", vm?.manifestPath ?? "-"),
                            ("Boot Loader", vm?.bootLoaderKind ?? "-"),
                            ("Docker Socket", vm?.dockerSocketPath ?? "-"),
                            ("Root Disk", vm?.rootDiskPath ?? "-"),
                            ("Data Disk", vm?.dataDiskPath ?? "-"),
                            ("Serial Log", vm?.serialLogPath ?? "-")
                        ])
                    }

                    AppCard("Profiles") {
                        if app.snapshot.profiles.isEmpty {
                            EmptyStateView(
                                systemImage: "person.crop.square",
                                title: "No Profiles",
                                message: "Profiles discovered from the runtime will appear here."
                            )
                            .frame(minHeight: 220)
                        } else {
                            FlowLayout(items: app.snapshot.profiles)
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

private struct FlowLayout: View {
    let items: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
            ForEach(items, id: \.self) { item in
                Label(item, systemImage: "person.crop.square")
                    .lineLimit(1)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

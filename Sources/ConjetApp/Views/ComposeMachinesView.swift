import SwiftUI

struct ComposeView: View {
    @EnvironmentObject private var app: ConjetAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HeaderView(title: "Compose", subtitle: app.composeDirectory, systemImage: "square.stack.3d.up")

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

            AppCard("Recent compose output") {
                if let entry = app.commandLog.first(where: { $0.label.hasPrefix("Compose") }) {
                    OutputBlock(text: [entry.stdout, entry.stderr].filter { !$0.isEmpty }.joined(separator: "\n"))
                } else {
                    Text("No compose commands")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .page()
    }
}

struct MachinesView: View {
    @EnvironmentObject private var app: ConjetAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HeaderView(title: "VM Machines", subtitle: app.snapshot.daemonResponse?.status?.vm?.message, systemImage: "desktopcomputer")

            AppCard("Runtime VM") {
                HStack {
                    StatusBadge(
                        text: app.snapshot.daemonResponse?.status?.vm?.state.rawValue ?? "unknown",
                        state: app.snapshot.daemonResponse?.status?.vm?.state == .running ? .good : .neutral
                    )
                    Spacer()
                    CommandBarButton(title: "Start", systemImage: "play.fill") { Task { await app.vm("start") } }
                    CommandBarButton(title: "Stop", systemImage: "stop.fill") { Task { await app.vm("stop") } }
                    CommandBarButton(title: "Logs", systemImage: "doc.text") { Task { await app.vm("logs") } }
                    CommandBarButton(title: "Fetch Core", systemImage: "arrow.down.circle") { Task { await app.vm("fetchCore") } }
                }
                let vm = app.snapshot.daemonResponse?.status?.vm
                KeyValueRows(rows: [
                    ("configured", (vm?.configured ?? false) ? "yes" : "no"),
                    ("manifest", vm?.manifestPath ?? "-"),
                    ("boot loader", vm?.bootLoaderKind ?? "-"),
                    ("docker socket", vm?.dockerSocketPath ?? "-"),
                    ("root disk", vm?.rootDiskPath ?? "-"),
                    ("data disk", vm?.dataDiskPath ?? "-"),
                    ("serial log", vm?.serialLogPath ?? "-")
                ])
            }

            AppCard("Profiles") {
                if app.snapshot.profiles.isEmpty {
                    Text("No profiles")
                        .foregroundStyle(.secondary)
                } else {
                    FlowLayout(items: app.snapshot.profiles)
                }
            }
        }
        .page()
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

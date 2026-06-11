import ConjetAppCore
import SwiftUI

struct ContainersView: View {
    @EnvironmentObject private var app: ConjetAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HeaderView(title: "Containers", subtitle: "\(app.snapshot.containers.count) tracked", systemImage: "shippingbox")

            AppCard("Run") {
                HStack {
                    TextField("Image", text: $app.runImage)
                        .textFieldStyle(.roundedBorder)
                    TextField("Command", text: $app.runCommand)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        Task { await app.runContainer() }
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                }
            }

            HSplitView {
                List(selection: $app.selectedContainerID) {
                    ForEach(app.snapshot.containers) { container in
                        ContainerRow(container: container)
                            .tag(container.id)
                    }
                }
                .frame(minWidth: 330)

                if let container = app.selectedContainer {
                    ContainerDetail(container: container)
                        .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    AppCard { Text("No containers") }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(minHeight: 430)
        }
        .page()
    }
}

private struct ContainerRow: View {
    let container: DockerContainer

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: container.state.lowercased() == "running" ? "play.circle.fill" : "circle")
                .foregroundStyle(container.state.lowercased() == "running" ? .green : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(container.name)
                    .lineLimit(1)
                Text(container.image)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
    }
}

private struct ContainerDetail: View {
    @EnvironmentObject private var app: ConjetAppState
    let container: DockerContainer

    var body: some View {
        AppCard(container.name) {
            HStack {
                StatusBadge(
                    text: container.state,
                    state: container.state.lowercased() == "running" ? .good : .neutral
                )
                Spacer()
                CommandBarButton(title: "Start", systemImage: "play.fill") {
                    Task { await app.containerAction("start", container: container) }
                }
                CommandBarButton(title: "Stop", systemImage: "stop.fill") {
                    Task { await app.containerAction("stop", container: container) }
                }
                CommandBarButton(title: "Restart", systemImage: "arrow.clockwise") {
                    Task { await app.containerAction("restart", container: container) }
                }
                CommandBarButton(title: "Remove", systemImage: "trash", role: .destructive) {
                    Task { await app.containerAction("remove", container: container) }
                }
            }
            KeyValueRows(rows: [
                ("id", container.id),
                ("image", container.image),
                ("command", container.command),
                ("status", container.status),
                ("ports", container.ports),
                ("created", container.createdAt),
                ("size", container.size)
            ])
        }
    }
}

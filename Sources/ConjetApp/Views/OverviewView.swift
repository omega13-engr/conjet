import ConjetAppCore
import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var app: ConjetAppState

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(
                title: "Conjet Runtime",
                subtitle: app.snapshot.daemonResponse?.message,
                systemImage: "gauge.with.dots.needle.67percent"
            )
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                        MetricCard(
                            title: "Daemon",
                            value: app.snapshot.daemonResponse?.status?.state.rawValue ?? "offline",
                            detail: app.snapshot.daemonResponse?.status.map { "pid \($0.pid)" } ?? app.snapshot.dockerSocketPath,
                            systemImage: "bolt.horizontal.circle",
                            tint: .green
                        )
                        MetricCard(
                            title: "Containers",
                            value: "\(app.snapshot.containers.count)",
                            detail: "\(app.snapshot.containers.filter { $0.state.lowercased() == "running" }.count) running",
                            systemImage: "shippingbox",
                            tint: .blue
                        )
                        MetricCard(
                            title: "Images",
                            value: "\(app.snapshot.images.count)",
                            detail: "\(app.snapshot.volumes.count) volumes",
                            systemImage: "opticaldiscdrive",
                            tint: .purple
                        )
                        MetricCard(
                            title: "Network",
                            value: "\(app.snapshot.daemonResponse?.status?.network?.activeTCPForwards ?? 0) TCP",
                            detail: "\(app.snapshot.daemonResponse?.status?.network?.failedForwards ?? 0) failed forwards",
                            systemImage: "network",
                            tint: .teal
                        )
                    }

                    AppCard("Runtime Controls") {
                        HStack {
                            daemonBadge(app.snapshot.daemonResponse)
                            Spacer()
                            CommandBarButton(title: "Start", systemImage: "play.fill") {
                                Task { await app.startRuntime() }
                            }
                            CommandBarButton(title: "Restart", systemImage: "arrow.triangle.2.circlepath") {
                                Task { await app.restartRuntime() }
                            }
                            CommandBarButton(title: "Stop", systemImage: "stop.fill", role: .destructive) {
                                Task { await app.stopRuntime() }
                            }
                            CommandBarButton(title: "Update Core", systemImage: "arrow.down.circle") {
                                Task { await app.updateRuntime() }
                            }
                        }
                    }

                    AppCard("Toolchain") {
                        KeyValueRows(rows: [
                            ("Conjet", "\(app.snapshot.conjetTool.executable) (\(app.snapshot.conjetTool.source))"),
                            ("Conjetd", "\(app.snapshot.conjetdTool.executable) (\(app.snapshot.conjetdTool.source))"),
                            ("Docker", "\(app.snapshot.dockerTool.executable) (\(app.snapshot.dockerTool.source))"),
                            ("Socket", app.snapshot.dockerSocketPath),
                            ("Socket State", app.snapshot.dockerSocketAvailable ? "available" : "missing")
                        ])
                    }

                    if !app.snapshot.warnings.isEmpty {
                        AppCard("Warnings") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(app.snapshot.warnings, id: \.self) { warning in
                                    Label(warning, systemImage: "exclamationmark.triangle")
                                        .foregroundStyle(.orange)
                                        .lineLimit(3)
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

import ConjetAppCore
import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var app: ConjetAppState

    var body: some View {
        let runtime = app.runtimeHealth
        let lifecycleAction = runtimeLifecycleAction

        VStack(spacing: 0) {
            HeaderView(
                title: "Conjet Runtime",
                subtitle: runtime.subtitle,
                systemImage: "gauge.with.dots.needle.67percent"
            )
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                        MetricCard(
                            title: "Daemon",
                            value: runtime.value,
                            detail: runtime.detail,
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
                            value: "\(app.snapshot.network?.activeTCPForwards ?? 0) TCP",
                            detail: "\(app.snapshot.network?.failedForwards ?? 0) failed forwards",
                            systemImage: "network",
                            tint: .teal
                        )
                    }

                    AppCard("Runtime Controls") {
                        HStack {
                            runtimeBadge(runtime)
                            Spacer()
                            CommandBarButton(
                                title: lifecycleAction.title,
                                systemImage: lifecycleAction.systemImage,
                                role: lifecycleAction.role
                            ) {
                                Task { await lifecycleAction.run() }
                            }
                            .disabled(app.activeCommandLabel != nil)
                            CommandBarButton(title: "Restart", systemImage: "arrow.triangle.2.circlepath") {
                                Task { await app.restartRuntime() }
                            }
                            CommandBarButton(title: "Update Core", systemImage: "arrow.down.circle") {
                                Task { await app.updateRuntime() }
                            }
                        }
                    }

                    AppCard("Toolchain") {
                        KeyValueRows(rows: [
                            ("Conjet", "\(app.snapshot.conjetTool.executable) (\(app.snapshot.conjetTool.source))"),
                            ("Conjet Core", "\(app.snapshot.conjetCoreTool.executable) (\(app.snapshot.conjetCoreTool.source))"),
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

    private var runtimeLifecycleAction: LifecycleAction {
        switch app.currentVMState {
        case .running, .starting:
            LifecycleAction(title: "Stop", systemImage: "stop.fill", role: .destructive) {
                await app.stopRuntime()
            }
        case .stopping, .stopped, .unconfigured, .error, nil:
            LifecycleAction(title: "Start", systemImage: "play.fill") {
                await app.startRuntime()
            }
        }
    }
}

@testable import ConjetApp
@testable import ConjetAppCore
import AppKit
import ConjetCore
import SwiftUI
import XCTest

final class ConjetAppSnapshotTests: XCTestCase {
    @MainActor
    func testWritesQAScreenshotsWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["CONJET_QA_SCREENSHOT_DIR"],
              !directory.isEmpty else {
            throw XCTSkip("Set CONJET_QA_SCREENSHOT_DIR to write QA screenshots.")
        }

        let outputDirectory = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let app = ConjetAppState()
        app.snapshot = Self.qaSnapshot()
        app.selectedContainerID = app.snapshot.containers.first?.id
        let defaults = UserDefaults.standard
        let collapsedKey = "containers.dockerEditorCollapsed"
        let previousCollapsedValue = defaults.object(forKey: collapsedKey)
        defer {
            if let previousCollapsedValue {
                defaults.set(previousCollapsedValue, forKey: collapsedKey)
            } else {
                defaults.removeObject(forKey: collapsedKey)
            }
        }

        try render(section: .overview, app: app, to: outputDirectory.appendingPathComponent("overview.png"))
        defaults.set(false, forKey: collapsedKey)
        try render(section: .containers, app: app, to: outputDirectory.appendingPathComponent("containers.png"))
        defaults.set(true, forKey: collapsedKey)
        try render(section: .containers, app: app, to: outputDirectory.appendingPathComponent("containers-collapsed.png"))
        try render(section: .images, app: app, to: outputDirectory.appendingPathComponent("images.png"))
    }

    @MainActor
    private func render(section: ManagementSection, app: ConjetAppState, to url: URL) throws {
        app.selectedSection = section
        if section == .images {
            app.selectedImageID = app.snapshot.images.first?.selectionID
        }

        let root = SnapshotHarness(section: section)
            .environmentObject(app)
            .frame(width: 1080, height: 720)
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.close() }

        let view = controller.view
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = NSRect(x: 0, y: 0, width: 1080, height: 720)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            XCTFail("Could not create bitmap representation for \(section.rawValue)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            XCTFail("Could not encode PNG for \(section.rawValue)")
            return
        }
        try data.write(to: url, options: .atomic)
    }

    private static func qaSnapshot() -> DashboardSnapshot {
        let tool = ResolvedTool(executable: "/tmp/conjet-ui-qa/tool", source: "test")
        let socketPath = "/tmp/conjet-ui-qa/home/run/docker.sock"
        let containers = [
            DockerContainer(
                id: "c1",
                name: "chum-mem-api-1",
                image: "chum-mem-api",
                state: "running",
                status: "Up 10 minutes (healthy)",
                labels: "com.docker.compose.project=chum-mem,com.docker.compose.service=api,com.docker.compose.project.working_dir=/Users/sly/Workspace/Org/chum-mem,com.docker.compose.project.config_files=/Users/sly/Workspace/Org/chum-mem/docker-compose.yml"
            ),
            DockerContainer(
                id: "c2",
                name: "chum-mem-worker-1",
                image: "chum-mem-worker",
                state: "running",
                status: "Up 9 minutes (health: starting)",
                labels: "com.docker.compose.project=chum-mem,com.docker.compose.service=worker,com.docker.compose.project.working_dir=/Users/sly/Workspace/Org/chum-mem,com.docker.compose.project.config_files=/Users/sly/Workspace/Org/chum-mem/docker-compose.yml"
            )
        ]
        let images = [
            DockerImage(
                id: "sha256:stable",
                repository: "nginx",
                tag: "alpine",
                size: "92.6MB",
                createdAt: "2026-05-23 02:30:41 +0800 PST",
                createdSince: "3 weeks ago"
            ),
            DockerImage(
                id: "sha256:stable",
                repository: "nginx",
                tag: "1.31-alpine",
                size: "92.6MB",
                createdAt: "2026-05-23 02:30:41 +0800 PST",
                createdSince: "3 weeks ago"
            ),
            DockerImage(
                id: "sha256:redis",
                repository: "redis",
                tag: "7.2",
                size: "191MB",
                createdAt: "2026-05-24 10:00:00 +0800 PST",
                createdSince: "3 weeks ago"
            )
        ]
        let volumes = [
            DockerVolume(
                name: "db_data",
                driver: "local",
                scope: "local",
                mountpoint: "/var/lib/docker/volumes/db_data/_data",
                labels: "",
                size: "42MB"
            )
        ]
        let stats = [
            DockerStats(
                container: "c1",
                name: "api",
                cpuPercent: "1.0%",
                memoryUsage: "16MiB / 2GiB",
                memoryPercent: "0.8%",
                networkIO: "1kB / 1kB",
                blockIO: "0B / 0B",
                pids: "4"
            )
        ]

        return DashboardSnapshot(
            conjetTool: tool,
            conjetdTool: tool,
            dockerTool: tool,
            dockerSocketPath: socketPath,
            dockerSocketAvailable: true,
            dockerReachable: true,
            daemonResponse: DaemonResponse(
                ok: true,
                message: "running",
                status: DaemonStatus(
                    pid: 123,
                    startedAt: Date(timeIntervalSince1970: 1_751_000_000),
                    state: .warmIdle,
                    socketPath: "/tmp/conjet-ui-qa/home/run/conjetd.sock",
                    host: HostCapabilities.detect(),
                    config: .default,
                    vm: VMRuntimeStatus(
                        state: .running,
                        configured: true,
                        manifestPath: "/tmp/conjet-ui-qa/home/state/vm/manifest.json",
                        dockerSocketPath: socketPath,
                        message: "running"
                    ),
                    network: ConjetNetworkStatus(activeTCPForwards: 6, failedForwards: 0)
                ),
                vm: VMRuntimeStatus(
                    state: .running,
                    configured: true,
                    manifestPath: "/tmp/conjet-ui-qa/home/state/vm/manifest.json",
                    dockerSocketPath: socketPath,
                    message: "running"
                )
            ),
            profiles: ["default"],
            containers: containers,
            images: images,
            volumes: volumes,
            stats: stats,
            containerActivity: ContainerActivitySnapshot(containers: containers, stats: stats, processes: []),
            warnings: []
        )
    }
}

private struct SnapshotHarness: View {
    let section: ManagementSection

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(selection: .constant(section))
                .frame(width: 172)
            Divider()
            switch section {
            case .overview:
                OverviewView()
            case .containers:
                ContainersView()
            case .images:
                ImagesView()
            default:
                OverviewView()
            }
        }
        .frame(width: 1080, height: 720)
        .background(.regularMaterial)
    }
}

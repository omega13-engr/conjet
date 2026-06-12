import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var app: ConjetAppState

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(selection: $app.selectedSection)
                .frame(width: 172)

            Divider()

            DetailView(section: app.selectedSection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 1080, minHeight: 720)
        .background(.regularMaterial)
        .task {
            ConjetWindowPresenter.configure(app: app)
            app.startAutoRefresh()
        }
    }
}

private struct DetailView: View {
    let section: ManagementSection

    var body: some View {
        switch section {
        case .overview:
            OverviewView()
        case .containers:
            ContainersView()
        case .compose:
            ComposeView()
        case .machines:
            MachinesView()
        case .images:
            ImagesView()
        case .volumes:
            VolumesView()
        case .activity:
            ActivityMonitorView()
        case .network:
            NetworkMonitorView()
        case .processes:
            ProcessCommandsView()
        case .commands:
            CommandLogView()
        }
    }
}

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var app: ConjetAppState

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $app.selectedSection)
        } detail: {
            DetailView(section: app.selectedSection)
        }
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

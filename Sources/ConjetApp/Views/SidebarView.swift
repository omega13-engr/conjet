import SwiftUI

struct SidebarView: View {
    @Binding var selection: ManagementSection

    var body: some View {
        List(selection: $selection) {
            Section("Conjet") {
                ForEach(ManagementSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Conjet")
    }
}

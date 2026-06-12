import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var app: ConjetAppState
    @Binding var selection: ManagementSection

    private let groups: [SidebarGroup] = [
        SidebarGroup(
            title: "Conjet",
            sections: [.overview, .containers, .compose]
        ),
        SidebarGroup(
            title: "Resources",
            sections: [.images, .volumes, .network]
        ),
        SidebarGroup(
            title: "Runtime",
            sections: [.machines, .activity, .processes, .commands]
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarBrand()
                .padding(.top, 44)
                .padding(.horizontal, 18)
                .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 18) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)
                            .padding(.horizontal, 18)

                        VStack(spacing: 3) {
                            ForEach(group.sections) { section in
                                SidebarRow(
                                    section: section,
                                    isSelected: selection == section
                                ) {
                                    selection = section
                                }
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 18)

            Spacer(minLength: 18)

            SidebarRuntimeStatus()
                .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.bar)
    }
}

private struct SidebarGroup: Identifiable {
    var title: String
    var sections: [ManagementSection]

    var id: String { title }
}

private struct SidebarBrand: View {
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.blue.gradient)
                Image(systemName: "bolt.horizontal.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text("Conjet")
                    .font(.headline.weight(.semibold))
                Text("Container Studio")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct SidebarRow: View {
    let section: ManagementSection
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 18)
                Text(section.title)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.blue)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
    }
}

private struct SidebarRuntimeStatus: View {
    @EnvironmentObject private var app: ConjetAppState

    private var isOnline: Bool {
        app.snapshot.daemonResponse?.ok == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isOnline ? .green : .orange)
                    .frame(width: 8, height: 8)
                Text(isOnline ? "Engine online" : "Engine idle")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }

            Text(app.snapshot.dockerSocketAvailable ? app.snapshot.dockerSocketPath : "Docker socket unavailable")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

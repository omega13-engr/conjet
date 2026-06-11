import ConjetAppCore
import SwiftUI

struct ImagesView: View {
    @EnvironmentObject private var app: ConjetAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HeaderView(title: "Images", subtitle: "\(app.snapshot.images.count) available", systemImage: "opticaldiscdrive")

            AppCard("Pull") {
                HStack {
                    TextField("Image", text: $app.pullImage)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        Task { await app.pullImageAction() }
                    } label: {
                        Label("Pull", systemImage: "arrow.down.circle")
                    }
                }
            }

            ResourceList(items: app.snapshot.images, selection: $app.selectedImageID) { image in
                VStack(alignment: .leading, spacing: 2) {
                    Text(image.reference)
                        .lineLimit(1)
                    Text("\(image.size) - \(image.createdSince)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } detail: { image in
                AppCard(image.reference) {
                    HStack {
                        Spacer()
                        CommandBarButton(title: "Remove", systemImage: "trash", role: .destructive) {
                            Task { await app.removeImage(image) }
                        }
                    }
                    KeyValueRows(rows: [
                        ("id", image.id),
                        ("repository", image.repository),
                        ("tag", image.tag),
                        ("size", image.size),
                        ("created", image.createdAt)
                    ])
                }
            }
        }
        .page()
    }
}

struct VolumesView: View {
    @EnvironmentObject private var app: ConjetAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HeaderView(title: "Volumes", subtitle: "\(app.snapshot.volumes.count) available", systemImage: "externaldrive")

            HStack {
                Spacer()
                CommandBarButton(title: "Prune", systemImage: "trash", role: .destructive) {
                    Task { await app.pruneVolumes() }
                }
            }

            ResourceList(items: app.snapshot.volumes, selection: $app.selectedVolumeID) { volume in
                VStack(alignment: .leading, spacing: 2) {
                    Text(volume.name)
                        .lineLimit(1)
                    Text(volume.driver)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } detail: { volume in
                AppCard(volume.name) {
                    HStack {
                        Spacer()
                        CommandBarButton(title: "Remove", systemImage: "trash", role: .destructive) {
                            Task { await app.removeVolume(volume) }
                        }
                    }
                    KeyValueRows(rows: [
                        ("driver", volume.driver),
                        ("scope", volume.scope),
                        ("mountpoint", volume.mountpoint),
                        ("labels", volume.labels)
                    ])
                }
            }
        }
        .page()
    }
}

private struct ResourceList<Item: Identifiable, Row: View, Detail: View>: View where Item.ID == String {
    let items: [Item]
    @Binding var selection: String?
    let row: (Item) -> Row
    let detail: (Item) -> Detail

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                ForEach(items) { item in
                    row(item)
                        .tag(item.id)
                }
            }
            .frame(minWidth: 330)

            if let selected = items.first(where: { $0.id == selection }) ?? items.first {
                detail(selected)
                    .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                AppCard { Text("No items").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(minHeight: 430)
    }
}

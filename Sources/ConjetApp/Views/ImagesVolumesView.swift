import ConjetAppCore
import SwiftUI

struct ImagesView: View {
    @EnvironmentObject private var app: ConjetAppState
    @State private var searchText = ""

    private var filteredImages: [DockerImage] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return app.snapshot.images }
        return app.snapshot.images.filter {
            $0.reference.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
                || $0.repository.localizedCaseInsensitiveContains(query)
                || $0.tag.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedImage: DockerImage? {
        filteredImages.first { $0.id == app.selectedImageID } ?? filteredImages.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(
                title: "Images",
                subtitle: "\(app.snapshot.images.count) available",
                systemImage: "opticaldiscdrive"
            )
            Divider()

            ResourceSplitView {
                ImageMasterPanel(
                    images: filteredImages,
                    totalCount: app.snapshot.images.count,
                    searchText: $searchText,
                    selection: $app.selectedImageID
                )
            } detail: {
                if let image = selectedImage {
                    ImageDetail(image: image)
                } else {
                    EmptyStateView(
                        systemImage: "opticaldiscdrive",
                        title: searchText.isEmpty ? "No Images" : "No Matching Images",
                        message: searchText.isEmpty
                            ? "Pull an image to populate the local registry."
                            : "Clear the search field to show every image."
                    )
                }
            }
        }
        .background(WorkbenchPalette.contentBackground)
    }
}

private struct ImageMasterPanel: View {
    @EnvironmentObject private var app: ConjetAppState

    let images: [DockerImage]
    let totalCount: Int
    @Binding var searchText: String
    @Binding var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Local Images", subtitle: "\(images.count) shown")
            SearchField(placeholder: "Search images", text: $searchText)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            Divider()

            if images.isEmpty {
                EmptyStateView(
                    systemImage: totalCount == 0 ? "opticaldiscdrive" : "magnifyingglass",
                    title: totalCount == 0 ? "No Images" : "No Results",
                    message: totalCount == 0
                        ? "Pull an image from the panel below."
                        : "Try a different repository, tag, or image ID."
                )
            } else {
                List(selection: $selection) {
                    ForEach(images) { image in
                        ImageRow(image: image)
                            .tag(image.id)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }

            Divider()
            PullImagePanel()
        }
    }
}

private struct PullImagePanel: View {
    @EnvironmentObject private var app: ConjetAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pull")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("Image", text: $app.pullImage)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                CommandBarButton(title: "Pull", systemImage: "arrow.down.circle") {
                    Task { await app.pullImageAction() }
                }
                .disabled(app.pullImage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(.regularMaterial)
    }
}

private struct ImageRow: View {
    let image: DockerImage

    var body: some View {
        HStack(spacing: 10) {
            ResourceIcon(systemImage: "cube.box.fill", tint: .green, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(image.reference)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text("\(image.size) - \(image.createdSince)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(image.id)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            StatusBadge(text: image.tag, state: .neutral)
        }
    }
}

private struct ImageDetail: View {
    @EnvironmentObject private var app: ConjetAppState
    let image: DockerImage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ResourceIcon(systemImage: "cube.box.fill", tint: .green, size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(image.reference)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                        Text(image.id)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    CommandBarButton(title: "Remove", systemImage: "trash", role: .destructive) {
                        Task { await app.removeImage(image) }
                    }
                }

                InspectorSection("Info") {
                    KeyValueRows(rows: [
                        ("ID", image.id),
                        ("Repository", image.repository),
                        ("Tag", image.tag),
                        ("Size", image.size),
                        ("Created", image.createdAt),
                        ("Age", image.createdSince)
                    ])
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

struct VolumesView: View {
    @EnvironmentObject private var app: ConjetAppState
    @State private var searchText = ""

    private var filteredVolumes: [DockerVolume] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return app.snapshot.volumes }
        return app.snapshot.volumes.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.driver.localizedCaseInsensitiveContains(query)
                || $0.scope.localizedCaseInsensitiveContains(query)
                || $0.labels.localizedCaseInsensitiveContains(query)
                || $0.displaySize.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedVolume: DockerVolume? {
        filteredVolumes.first { $0.id == app.selectedVolumeID } ?? filteredVolumes.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(
                title: "Volumes",
                subtitle: "\(app.snapshot.volumes.count) available",
                systemImage: "externaldrive"
            ) {
                IconActionButton(title: "Prune unused volumes", systemImage: "trash", role: .destructive) {
                    Task { await app.pruneVolumes() }
                }
            }
            Divider()

            ResourceSplitView {
                VolumeMasterPanel(
                    volumes: filteredVolumes,
                    totalCount: app.snapshot.volumes.count,
                    searchText: $searchText,
                    selection: $app.selectedVolumeID
                )
            } detail: {
                if let volume = selectedVolume {
                    VolumeDetail(volume: volume)
                } else {
                    EmptyStateView(
                        systemImage: "externaldrive",
                        title: searchText.isEmpty ? "No Volumes" : "No Matching Volumes",
                        message: searchText.isEmpty
                            ? "Docker volumes will appear here after workloads create persistent storage."
                            : "Clear the search field to show every volume."
                    )
                }
            }
        }
        .background(WorkbenchPalette.contentBackground)
    }
}

private struct VolumeMasterPanel: View {
    let volumes: [DockerVolume]
    let totalCount: Int
    @Binding var searchText: String
    @Binding var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Storage", subtitle: "\(volumes.count) shown")
            SearchField(placeholder: "Search volumes", text: $searchText)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            Divider()

            if volumes.isEmpty {
                EmptyStateView(
                    systemImage: totalCount == 0 ? "externaldrive" : "magnifyingglass",
                    title: totalCount == 0 ? "No Volumes" : "No Results",
                    message: totalCount == 0
                        ? "Persistent Docker storage will show up here."
                        : "Try a different volume name, driver, scope, or label."
                )
            } else {
                List(selection: $selection) {
                    ForEach(volumes) { volume in
                        VolumeRow(volume: volume)
                            .tag(volume.id)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

private struct VolumeRow: View {
    let volume: DockerVolume

    var body: some View {
        HStack(spacing: 10) {
            ResourceIcon(systemImage: "externaldrive.fill", tint: .purple, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(volume.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text("\(volume.driver) - \(volume.scope) - \(volume.displaySize)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !volume.labels.isEmpty {
                    Text(volume.labels)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if volume.displaySize != "-" {
                StatusBadge(text: volume.displaySize, state: .neutral)
            }
        }
    }
}

private struct VolumeDetail: View {
    @EnvironmentObject private var app: ConjetAppState
    let volume: DockerVolume

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ResourceIcon(systemImage: "externaldrive.fill", tint: .purple, size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(volume.name)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                        Text("\(volume.driver) driver - \(volume.displaySize)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    CommandBarButton(title: "Remove", systemImage: "trash", role: .destructive) {
                        Task { await app.removeVolume(volume) }
                    }
                }

                InspectorSection("Info") {
                    KeyValueRows(rows: [
                        ("Size", volume.displaySize),
                        ("Driver", volume.driver),
                        ("Scope", volume.scope),
                        ("Mountpoint", volume.mountpoint),
                        ("Labels", volume.labels)
                    ])
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

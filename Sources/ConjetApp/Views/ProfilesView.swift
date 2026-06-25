import ConjetAppCore
import ConjetCore
import SwiftUI

struct ProfilesView: View {
    @EnvironmentObject private var app: ConjetAppState
    @State private var searchText = ""

    private var filteredProfiles: [ConjetProfileContext] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return app.snapshot.profileContexts }
        return app.snapshot.profileContexts.filter { profile in
            profile.name.localizedCaseInsensitiveContains(query)
                || profile.homePath.localizedCaseInsensitiveContains(query)
                || profile.dockerSocketPath.localizedCaseInsensitiveContains(query)
                || profile.daemonSocketPath.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedProfile: ConjetProfileContext? {
        filteredProfiles.first { $0.name == app.selectedProfileName }
            ?? filteredProfiles.first { $0.isCurrent }
            ?? filteredProfiles.first
    }

    private var headerSubtitle: String {
        if let current = app.currentProfileContext {
            return "current \(current.name) - \(app.snapshot.profileContexts.count) available"
        }
        return "\(app.snapshot.profileContexts.count) available"
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(
                title: "Profiles",
                subtitle: headerSubtitle,
                systemImage: "person.crop.square"
            )
            Divider()

            ResourceSplitView {
                ProfileMasterPanel(
                    profiles: filteredProfiles,
                    totalCount: app.snapshot.profileContexts.count,
                    searchText: $searchText,
                    selection: $app.selectedProfileName
                )
            } detail: {
                if let profile = selectedProfile {
                    ProfileDetail(profile: profile, currentProfile: app.currentProfileContext)
                } else {
                    EmptyStateView(
                        systemImage: searchText.isEmpty ? "person.crop.square" : "magnifyingglass",
                        title: searchText.isEmpty ? "No Profiles" : "No Results",
                        message: searchText.isEmpty
                            ? "Profile context will appear after the runtime snapshot loads."
                            : "Try a different profile name or runtime path."
                    )
                }
            }
        }
        .background(WorkbenchPalette.contentBackground)
        .confirmationDialog(
            "Restart Profile?",
            isPresented: $app.showProfileRestartPrompt,
            titleVisibility: .visible
        ) {
            Button("Restart Now") {
                Task { await app.restartPendingProfileNow() }
            }
            Button("Restart Later", role: .cancel) {
                app.restartPendingProfileLater()
            }
        } message: {
            if let profile = app.pendingRestartProfileName {
                Text("Saved settings require restarting \(profile).")
            }
        }
    }
}

private struct ProfileMasterPanel: View {
    let profiles: [ConjetProfileContext]
    let totalCount: Int
    @Binding var searchText: String
    @Binding var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Profiles", subtitle: "\(profiles.count) shown")
            SearchField(placeholder: "Search profiles", text: $searchText)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            Divider()

            if profiles.isEmpty {
                EmptyStateView(
                    systemImage: totalCount == 0 ? "person.crop.square" : "magnifyingglass",
                    title: totalCount == 0 ? "No Profiles" : "No Results",
                    message: totalCount == 0
                        ? "Profile context will appear after the runtime snapshot loads."
                        : "Try a different profile name or runtime path."
                )
            } else {
                List(selection: $selection) {
                    ForEach(profiles) { profile in
                        ProfileRow(profile: profile)
                            .tag(profile.name)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }

            Divider()
            CreateProfilePanel()
        }
    }
}

private struct CreateProfilePanel: View {
    @EnvironmentObject private var app: ConjetAppState

    private var trimmedProfileName: String {
        app.newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !trimmedProfileName.isEmpty && app.activeCommandLabel == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Create")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("Profile name", text: $app.newProfileName)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Spacer()
                CommandBarButton(title: "Create", systemImage: "plus") {
                    Task { await app.createProfile(switchToNew: false) }
                }
                .disabled(!canSubmit)
                CommandBarButton(title: "Create & Use", systemImage: "checkmark.circle") {
                    Task { await app.createProfile(switchToNew: true) }
                }
                .disabled(!canSubmit)
            }

            if let message = app.profileActionMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let error = app.profileActionError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(.regularMaterial)
    }
}

private struct ProfileRow: View {
    let profile: ConjetProfileContext

    var body: some View {
        HStack(spacing: 10) {
            ResourceIcon(
                systemImage: profile.isCurrent ? "person.crop.square.fill" : "person.crop.square",
                tint: profile.isCurrent ? .blue : .secondary,
                size: 28
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(profile.homePath.isEmpty ? "profile context unavailable" : profile.homePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !profile.dockerSocketPath.isEmpty {
                    Text(profile.dockerSocketPath)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            StatusBadge(text: profile.statusText, state: profile.isCurrent ? .good : .neutral)
        }
    }
}

private struct ProfileDetail: View {
    @EnvironmentObject private var app: ConjetAppState
    let profile: ConjetProfileContext
    let currentProfile: ConjetProfileContext?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ResourceIcon(
                        systemImage: profile.isCurrent ? "person.crop.square.fill" : "person.crop.square",
                        tint: profile.isCurrent ? .blue : .secondary,
                        size: 34
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.name)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                        Text(profile.homePath.isEmpty ? "profile context unavailable" : profile.homePath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    CommandBarButton(title: "Use Profile", systemImage: "checkmark.circle") {
                        Task { await app.switchProfile(profile) }
                    }
                    .disabled(profile.isCurrent || app.activeCommandLabel != nil)
                    StatusBadge(text: profile.statusText, state: profile.isCurrent ? .good : .neutral)
                }

                InspectorSection("Profile Context") {
                    KeyValueRows(rows: [
                        ("Profile", profile.name),
                        ("Current", profile.isCurrent ? "yes" : "no"),
                        ("Root Home", profile.rootHomePath),
                        ("Home", profile.homePath),
                        ("Config", profile.configPath)
                    ])
                }

                ProfileConfigEditor(profile: profile)

                InspectorSection("Runtime Paths") {
                    KeyValueRows(rows: [
                        ("Run Directory", profile.runDirectoryPath),
                        ("Daemon Socket", profile.daemonSocketPath),
                        ("Docker Socket", profile.dockerSocketPath),
                        ("State", profile.stateDirectoryPath),
                        ("VM Manifest", profile.vmManifestPath)
                    ])
                }

                InspectorSection("Logs") {
                    KeyValueRows(rows: [
                        ("Directory", profile.logsDirectoryPath),
                        ("Daemon", profile.daemonLogPath),
                        ("VM Serial", profile.serialLogPath)
                    ])
                }

                if let currentProfile, currentProfile.name != profile.name {
                    InspectorSection("Active Runtime") {
                        KeyValueRows(rows: [
                            ("Profile", currentProfile.name),
                            ("Docker Socket", currentProfile.dockerSocketPath),
                            ("Daemon Socket", currentProfile.daemonSocketPath)
                        ])
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

private struct ProfileConfigEditor: View {
    @EnvironmentObject private var app: ConjetAppState
    let profile: ConjetProfileContext

    private var draft: Binding<ProfileConfigDraft>? {
        guard app.profileConfigDraft?.profileName == profile.name else { return nil }
        return Binding(
            get: {
                app.profileConfigDraft ?? ProfileConfigDraft(profileName: profile.name, config: .default)
            },
            set: { app.profileConfigDraft = $0 }
        )
    }

    var body: some View {
        InspectorSection("Settings") {
            if let draft {
                ProfileConfigForm(draft: draft)

                HStack(spacing: 8) {
                    if let message = app.profileConfigMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let error = app.profileConfigError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(3)
                    }
                    Spacer(minLength: 8)
                    CommandBarButton(title: "Reload", systemImage: "arrow.clockwise") {
                        app.loadProfileConfig(profile, force: true)
                    }
                    .disabled(app.activeCommandLabel != nil)
                    CommandBarButton(title: "Save", systemImage: "square.and.arrow.down") {
                        Task { await app.saveProfileConfig() }
                    }
                    .disabled(app.activeCommandLabel != nil)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(app.profileConfigError ?? "Loading settings")
                        .font(.caption)
                        .foregroundStyle(app.profileConfigError == nil ? Color.secondary : Color.red)
                }
            }
        }
        .task(id: profile.name) {
            app.loadProfileConfig(profile)
        }
    }
}

private struct ProfileConfigForm: View {
    @EnvironmentObject private var app: ConjetAppState
    @Binding var draft: ProfileConfigDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ConfigGroup("VM") {
                ConfigGrid {
                    NumberField(title: "CPUs", value: $draft.vmCPUs)
                    MemorySliderField(
                        memoryMiB: $draft.memoryMiB,
                        bounds: app.profileMemoryBounds
                    )
                    NumberField(title: "Disk GiB", value: $draft.diskGiB)
                    FieldStack("Architecture") {
                        Picker("Architecture", selection: $draft.architecture) {
                            Text("aarch64").tag("aarch64")
                            Text("x86_64").tag("x86_64")
                        }
                        .labelsHidden()
                    }
                }

                ConfigGrid {
                    FieldStack("Memory") {
                        Picker("Memory", selection: $draft.memoryProfile) {
                            ForEach(ConjetMemoryProfile.allCases, id: \.self) { profile in
                                Text(label(profile.rawValue)).tag(profile)
                            }
                        }
                        .labelsHidden()
                    }
                    FieldStack("Energy") {
                        Picker("Energy", selection: $draft.energyMode) {
                            ForEach(ConjetEnergyMode.allCases, id: \.self) { mode in
                                Text(label(mode.rawValue)).tag(mode)
                            }
                        }
                        .labelsHidden()
                    }
                    FieldStack("Runtime") {
                        Picker("Runtime", selection: $draft.runtime) {
                            ForEach(ConjetContainerRuntimeKind.allCases, id: \.self) { runtime in
                                Text(label(runtime.rawValue)).tag(runtime.rawValue)
                            }
                        }
                        .labelsHidden()
                    }
                }

                ToggleGrid {
                    Toggle("Rosetta", isOn: $draft.enableRosetta)
                    Toggle("Host Mounts", isOn: $draft.enableHostMounts)
                    Toggle("Removable Mounts", isOn: $draft.enableRemovableHostMounts)
                }

                PathField(title: "Disk Image", text: $draft.diskImagePath)
            }

            Divider()

            ConfigGroup("Daemon") {
                ConfigGrid {
                    NumberField(title: "Quiet Stop Min", value: $draft.quietStopMinutes)
                    PathField(title: "Socket", text: $draft.socketPath)
                }
                PathField(title: "Core Repo", text: $draft.conjetCoreRepository)
            }

            Divider()

            ConfigGroup("Network") {
                ConfigGrid {
                    FieldStack("Bind") {
                        Picker("Bind", selection: $draft.networkBindPolicy) {
                            ForEach(ConjetNetworkBindPolicy.allCases, id: \.self) { policy in
                                Text(label(policy.rawValue)).tag(policy)
                            }
                        }
                        .labelsHidden()
                    }
                    FieldStack("Proxy") {
                        Picker("Proxy", selection: $draft.networkProxyEngine) {
                            ForEach(ConjetNetworkProxyEngine.allCases, id: \.self) { engine in
                                Text(label(engine.rawValue)).tag(engine)
                            }
                        }
                        .labelsHidden()
                    }
                    FieldStack("Bridge") {
                        Picker("Bridge", selection: $draft.networkBridgeEngine) {
                            ForEach(ConjetNetworkBridgeEngine.allCases, id: \.self) { engine in
                                Text(label(engine.rawValue)).tag(engine)
                            }
                        }
                        .labelsHidden()
                    }
                }
                PathField(title: "LAN CIDRs", text: $draft.networkLANAllowedCIDRs)
                PathField(title: "LAN Ports", text: $draft.networkLANAllowedPorts)
            }

            Divider()

            ConfigGroup("SSH") {
                ConfigGrid {
                    Toggle("Enabled", isOn: $draft.sshEnabled)
                    FieldStack("Transport") {
                        Picker("Transport", selection: $draft.sshTransport) {
                            Text("proxy-command").tag("proxy-command")
                            Text("tcp").tag("tcp")
                        }
                        .labelsHidden()
                    }
                    Toggle("TCP Fallback", isOn: $draft.sshAllowTCPFallback)
                }
            }
        }
    }

    private func label(_ value: String) -> String {
        value
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}

private struct ConfigGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

private struct ConfigGrid<Content: View>: View {
    @ViewBuilder var content: Content

    private let columns = [
        GridItem(.adaptive(minimum: 138), spacing: 12, alignment: .leading)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            content
        }
    }
}

private struct ToggleGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 16) {
            content
            Spacer(minLength: 0)
        }
    }
}

private struct FieldStack<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct NumberField: View {
    let title: String
    @Binding var value: Int

    var body: some View {
        FieldStack(title) {
            TextField(title, value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct MemorySliderField: View {
    @Binding var memoryMiB: Int
    let bounds: ConjetProfileMemoryBounds

    private var memoryGiB: Int {
        bounds.clampedMiB(memoryMiB) / 1024
    }

    private var sliderValue: Binding<Double> {
        Binding(
            get: { Double(memoryGiB) },
            set: { newValue in
                memoryMiB = bounds.miB(forGiB: Int(newValue.rounded()))
            }
        )
    }

    var body: some View {
        FieldStack("Memory") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("\(memoryGiB) GiB")
                        .font(.callout.weight(.semibold).monospacedDigit())
                    Spacer(minLength: 8)
                    Text("\(bounds.minimumGiB)-\(bounds.maximumGiB) GiB")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Slider(
                    value: sliderValue,
                    in: Double(bounds.minimumGiB)...Double(bounds.maximumGiB),
                    step: 1
                )
            }
        }
        .onAppear {
            memoryMiB = bounds.clampedMiB(memoryMiB)
        }
    }
}

private struct PathField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        FieldStack(title) {
            TextField(title, text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

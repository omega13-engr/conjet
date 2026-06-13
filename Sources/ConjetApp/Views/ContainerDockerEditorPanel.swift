import SwiftUI

struct ContainerDockerEditorPanel: View {
    @EnvironmentObject private var app: ConjetAppState
    @AppStorage("containers.dockerEditorCollapsed") private var isCollapsed = false

    private var canRun: Bool {
        !app.dockerEditorSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && app.activeCommandLabel == nil
    }

    private var latestEditorCommand: CommandState? {
        guard let entry = app.commandLog.first(where: {
            $0.label == "Build Dockerfile" || $0.label.hasPrefix("Run conjet-editor-")
        }) else {
            return nil
        }
        return CommandState(succeeded: entry.succeeded, label: entry.label)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isCollapsed.toggle()
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 10)
                        Image(systemName: "doc.plaintext")
                        Text("Dockerfile")
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                }
                .buttonStyle(.plain)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(WorkbenchPalette.border)
                    }
                    .help(isCollapsed ? "Expand Dockerfile editor" : "Collapse Dockerfile editor")

                TextField("Image tag", text: $app.dockerEditorImageTag)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(width: 160)

                if !isCollapsed {
                    TextField("Run args", text: $app.dockerEditorRunArguments)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                }

                if isCollapsed {
                    Spacer(minLength: 0)
                    buildButton
                    editorCommandStatus
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            if !isCollapsed {
                Divider()

                TextEditor(text: $app.dockerEditorSource)
                    .font(.system(.caption, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(WorkbenchPalette.contentBackground.opacity(0.55))
                    .frame(minHeight: 122)

                Divider()

                HStack(spacing: 10) {
                    buildButton
                    editorCommandStatus
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
        }
        .frame(height: isCollapsed ? 52 : 236)
        .background(.regularMaterial)
    }

    private var buildButton: some View {
        CommandBarButton(title: "Build & Run", systemImage: "play.fill") {
            Task { await app.runDockerEditor() }
        }
        .disabled(!canRun)
        .help("Build Dockerfile and run detached container")
    }

    @ViewBuilder
    private var editorCommandStatus: some View {
        if let active = app.activeCommandLabel,
           active == "Build Dockerfile" || active.hasPrefix("Run conjet-editor-") {
            ProgressView()
                .controlSize(.small)
                .help(active)
        } else if let latestEditorCommand {
            StatusBadge(
                text: latestEditorCommand.succeeded ? "ready" : "failed",
                state: latestEditorCommand.succeeded ? .good : .bad
            )
            .help(latestEditorCommand.label)
        }
    }
}

private struct CommandState {
    var succeeded: Bool
    var label: String
}

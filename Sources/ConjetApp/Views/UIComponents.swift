import ConjetAppCore
import ConjetCore
import SwiftUI

enum WorkbenchPalette {
    static let contentBackground = Color(nsColor: .windowBackgroundColor)
    static let panelBackground = Color(nsColor: .controlBackgroundColor)
    static let rowHover = Color.primary.opacity(0.045)
    static let border = Color.primary.opacity(0.09)
}

struct Page: ViewModifier {
    func body(content: Content) -> some View {
        ScrollView {
            content
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(WorkbenchPalette.contentBackground)
    }
}

extension View {
    func page() -> some View {
        modifier(Page())
    }
}

struct HeaderView<Actions: View>: View {
    @EnvironmentObject private var app: ConjetAppState

    let title: String
    let subtitle: String?
    let systemImage: String
    let actions: Actions

    init(
        title: String,
        subtitle: String?,
        systemImage: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ResourceIcon(systemImage: systemImage, tint: .blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 16)

            HStack(spacing: 8) {
                actions

                if let active = app.activeCommandLabel {
                    ProgressView(active)
                        .controlSize(.small)
                        .font(.caption)
                        .lineLimit(1)
                        .frame(maxWidth: 160, alignment: .trailing)
                }

                IconActionButton(title: "Refresh", systemImage: "arrow.clockwise") {
                    Task { await app.refresh() }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(app.isRefreshing)
            }
        }
        .padding(.top, 10)
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
        .background(.regularMaterial)
    }
}

extension HeaderView where Actions == EmptyView {
    init(title: String, subtitle: String?, systemImage: String) {
        self.init(title: title, subtitle: subtitle, systemImage: systemImage) {
            EmptyView()
        }
    }
}

struct PanelHeader<Actions: View>: View {
    let title: String
    let subtitle: String?
    let actions: Actions

    init(title: String, subtitle: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            actions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

extension PanelHeader where Actions == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct SearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(WorkbenchPalette.border)
        }
    }
}

struct ResourceSplitView<Master: View, Detail: View>: View {
    let master: Master
    let detail: Detail

    init(@ViewBuilder master: () -> Master, @ViewBuilder detail: () -> Detail) {
        self.master = master()
        self.detail = detail()
    }

    var body: some View {
        HSplitView {
            master
                .frame(minWidth: 340, idealWidth: 390, maxWidth: 480, maxHeight: .infinity)
                .background(WorkbenchPalette.panelBackground)

            detail
                .frame(minWidth: 470, maxWidth: .infinity, maxHeight: .infinity)
                .background(WorkbenchPalette.contentBackground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AppCard<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.callout.weight(.semibold))
            }
            content
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(WorkbenchPalette.border)
        }
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        AppCard(title) {
            content
        }
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    var tint: Color = .accentColor

    var body: some View {
        AppCard {
            HStack(alignment: .center, spacing: 10) {
                ResourceIcon(systemImage: systemImage, tint: tint, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct ResourceIcon: View {
    let systemImage: String
    var tint: Color
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.opacity(0.16))
            Image(systemName: systemImage)
                .font(.system(size: size * 0.47, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }
}

struct StatusBadge: View {
    let text: String
    var state: BadgeState = .neutral

    enum BadgeState {
        case good
        case warning
        case bad
        case neutral

        var color: Color {
            switch self {
            case .good: .green
            case .warning: .orange
            case .bad: .red
            case .neutral: .secondary
            }
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(state.color)
                .frame(width: 6, height: 6)
            Text(text.isEmpty ? "unknown" : text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(state.color.opacity(0.12), in: Capsule())
    }
}

struct IconActionButton: View {
    let title: String
    let systemImage: String
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.borderless)
        .background(.thinMaterial, in: Circle())
        .overlay {
            Circle().stroke(WorkbenchPalette.border)
        }
        .help(title)
        .accessibilityLabel(title)
    }
}

struct CommandBarButton: View {
    let title: String
    let systemImage: String
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
        }
        .controlSize(.small)
    }
}

struct KeyValueRows: View {
    let rows: [(String, String)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.0)
                        .foregroundStyle(.secondary)
                        .frame(width: 112, alignment: .leading)
                    Text(row.1.isEmpty ? "-" : row.1)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
                .padding(.vertical, 7)

                if index != rows.count - 1 {
                    Divider()
                }
            }
        }
    }
}

struct OutputBlock: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "No output" : text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(minHeight: 140, maxHeight: 320)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(WorkbenchPalette.border)
        }
    }
}

struct EmptyStateView<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String
    let actions: Actions

    init(
        systemImage: String,
        title: String,
        message: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: 330)
            actions
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(systemImage: String, title: String, message: String) {
        self.init(systemImage: systemImage, title: title, message: message) {
            EmptyView()
        }
    }
}

func daemonBadge(_ response: DaemonResponse?) -> StatusBadge {
    guard let response else {
        return StatusBadge(text: "offline", state: .bad)
    }
    if let state = response.status?.state.rawValue {
        return StatusBadge(text: state, state: response.ok ? .good : .warning)
    }
    return StatusBadge(text: response.ok ? "online" : "offline", state: response.ok ? .good : .bad)
}

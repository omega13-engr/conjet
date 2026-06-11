import ConjetAppCore
import ConjetCore
import SwiftUI

struct Page: ViewModifier {
    func body(content: Content) -> some View {
        ScrollView {
            content
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("")
    }
}

extension View {
    func page() -> some View {
        modifier(Page())
    }
}

struct HeaderView: View {
    @EnvironmentObject private var app: ConjetAppState

    let title: String
    let subtitle: String?
    let systemImage: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                if let active = app.activeCommandLabel {
                    ProgressView(active)
                        .controlSize(.small)
                        .lineLimit(1)
                }
                Button {
                    Task { await app.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(app.isRefreshing)
            }
            .frame(maxWidth: 260, alignment: .trailing)
        }
        .padding(.bottom, 4)
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
                    .font(.headline)
            }
            content
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
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
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(state.color.opacity(0.12), in: Capsule())
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
        }
    }
}

struct KeyValueRows: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            ForEach(rows, id: \.0) { key, value in
                GridRow {
                    Text(key)
                        .foregroundStyle(.secondary)
                    Text(value.isEmpty ? "-" : value)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }
        }
        .font(.callout)
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
        .frame(minHeight: 120, maxHeight: 280)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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

import SwiftUI

/// Left sidebar: two independent sections — Projects (top) and Agents (bottom).
/// Not nested; separate headings and data sources (shared row chrome only later).
struct SidebarView: View {
    @Binding var selectedProjectID: String?
    @Binding var selectedAgentID: String?
    var isFocused: Bool = false

    /// Static placeholders until SwiftData models land (T3).
    private let projects: [(id: String, name: String, status: RowStatus?)] = [
        ("website-redesign", "Website Redesign", .busy),
        ("q3-planning", "Q3 Planning", nil),
        ("tax-prep-2026", "Tax Prep 2026", .done),
    ]

    private let agents: [(id: String, name: String, status: RowStatus?)] = [
        ("research", "Research Assistant", nil),
        ("editor", "Writing Editor", nil),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title: "Projects") {
                // Creation flow is T11 — button is a non-functional shell affordance.
            }

            VStack(spacing: 0) {
                ForEach(projects, id: \.id) { project in
                    SidebarRowView(
                        title: project.name,
                        icon: "square.on.square",
                        status: project.status,
                        isSelected: selectedProjectID == project.id
                    ) {
                        selectedProjectID = project.id
                        selectedAgentID = nil
                    }
                }
            }

            sectionDivider

            sectionHeader(title: "Agents") {}

            VStack(spacing: 0) {
                ForEach(agents, id: \.id) { agent in
                    SidebarRowView(
                        title: agent.name,
                        icon: "diamond",
                        status: agent.status,
                        isSelected: selectedAgentID == agent.id
                    ) {
                        selectedAgentID = agent.id
                        // Agent selection does not clear Project — persona is cross-project.
                    }
                }
            }

            Spacer(minLength: 12)

            keyboardHints
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.sidebarBackground)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Theme.deepest)
                .frame(width: 1)
        }
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(Theme.focusRing, lineWidth: 2)
            }
        }
    }

    private func sectionHeader(title: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .textCase(.uppercase)
                .tracking(0.6)

            Spacer()

            Button(action: action) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .help("New \(title.dropLast())")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(Theme.borderStructural)
            .frame(height: 1)
            .padding(.top, 6)
            .padding(.bottom, 6)
    }

    private var keyboardHints: some View {
        Text("Panes: \(hint("⌘1")) Sidebar  \(hint("⌘2")) Chat  \(hint("⌘3")) Files  \(hint("⌘4")) Term")
            .font(.system(size: 10))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Pane shortcuts: Command 1 Sidebar, Command 2 Chat, Command 3 Files, Command 4 Terminal")
    }

    private func hint(_ keys: String) -> Text {
        Text(keys)
            .font(.system(size: 10).monospaced())
            .foregroundStyle(Theme.textTertiary)
    }
}

// MARK: - Row chrome (shared later by real Projects/Agents lists)

enum RowStatus {
    case busy
    case done

    var color: Color {
        switch self {
        case .busy: Theme.statusBusy
        case .done: Theme.statusDone
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .busy: "Streaming"
        case .done: "Unread activity"
        }
    }
}

struct SidebarRowView: View {
    let title: String
    let icon: String
    var status: RowStatus? = nil
    var isSelected: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 15)
                    .opacity(0.8)

                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let status {
                    Circle()
                        .fill(status.color)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel(status.accessibilityLabel)
                }
            }
            .foregroundStyle(isSelected ? Theme.textOnAccent : Theme.textRow)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Theme.selectionFill : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }
}

#Preview {
    SidebarView(selectedProjectID: .constant("website-redesign"), selectedAgentID: .constant(nil))
        .frame(width: 224, height: 600)
        .preferredColorScheme(.dark)
}

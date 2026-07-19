import SwiftData
import SwiftUI

/// Left sidebar: two independent sections — Projects (top) and Agents (bottom).
/// Not nested; separate headings and independent data sources. Shared row chrome
/// only (`SidebarRowView`) — pure code reuse, not a visual merge.
///
/// T3: SwiftData-backed lists. T11: creation sheets. T12: archive filter + action.
struct SidebarView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var selection: WorkspaceSelection

    var isFocused: Bool = false

    /// T12: default shows active Projects; toggle reveals archived.
    @State private var showArchived = false
    @State private var showProjectSheet = false
    @State private var showAgentSheet = false
    @State private var renameTarget: WorkspaceProject?
    @State private var renameText = ""

    @Query(sort: \WorkspaceProject.lastActiveAt, order: .reverse)
    private var allProjects: [WorkspaceProject]

    @Query(sort: \Agent.name, order: .forward)
    private var agents: [Agent]

    private var visibleProjects: [WorkspaceProject] {
        allProjects.filter { project in
            guard !project.isHiddenFromSidebar else { return false }
            return showArchived ? project.archived : !project.archived
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            projectsSection
            sectionDivider
            agentsSection
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
        .sheet(isPresented: $showProjectSheet) {
            ProjectCreationSheet { project in
                selection.selectProject(project)
            }
        }
        .sheet(isPresented: $showAgentSheet) {
            AgentCreationSheet { agent in
                let project = currentProject
                selection.selectAgent(agent, in: project, context: modelContext)
            }
        }
        .sheet(item: $renameTarget) { project in
            RenameProjectSheet(
                name: $renameText,
                isQuickChat: project.isQuickChat || project.isHiddenFromSidebar
            ) {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                project.name = trimmed
                if project.isHiddenFromSidebar || project.isQuickChat {
                    ProjectFactory.promoteToSidebar(project)
                }
                try? modelContext.save()
                renameTarget = nil
            } onCancel: {
                renameTarget = nil
            }
        }
    }

    // MARK: - Projects

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title: "Projects") {
                showProjectSheet = true
            }

            // Active / Archived filter toggle (T12) — same pattern as Claude/ChatGPT.
            HStack(spacing: 0) {
                filterChip(title: "Active", selected: !showArchived) {
                    showArchived = false
                }
                filterChip(title: "Archived", selected: showArchived) {
                    showArchived = true
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)

            if visibleProjects.isEmpty {
                emptyProjectsHint
            } else {
                VStack(spacing: 0) {
                    ForEach(visibleProjects, id: \.id) { project in
                        projectRow(project)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func projectRow(_ project: WorkspaceProject) -> some View {
        SidebarRowView(
            title: project.name,
            icon: "square.on.square",
            status: status(for: project),
            isSelected: selection.selectedProjectID == project.id
                && selection.selectedAgentID == nil
        ) {
            selection.selectProject(project)
            try? modelContext.save()
        }
        .contextMenu {
            if project.archived {
                Button("Unarchive") {
                    project.archived = false
                    try? modelContext.save()
                }
            } else {
                Button("Archive") {
                    archive(project)
                }
            }
            Button("Rename…") {
                renameText = project.name
                renameTarget = project
            }
            if project.isHiddenFromSidebar {
                Button("Show in sidebar") {
                    ProjectFactory.promoteToSidebar(project)
                    try? modelContext.save()
                }
            }
        }
    }

    private var emptyProjectsHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                showArchived
                    ? "No archived projects."
                    : "Group chats and files by what you're working on."
            )
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            if !showArchived {
                Button {
                    showProjectSheet = true
                } label: {
                    Text("＋ New Project")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accentText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Theme.accent, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Agents

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title: "Agents") {
                showAgentSheet = true
            }

            if agents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reusable personas — an editor, a researcher, a planner.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        showAgentSheet = true
                    } label: {
                        Text("＋ New Agent")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.accentText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Theme.accent, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(agents, id: \.id) { agent in
                        SidebarRowView(
                            title: agent.name,
                            icon: "diamond",
                            status: status(for: agent),
                            isSelected: selection.selectedAgentID == agent.id
                        ) {
                            selection.selectAgent(
                                agent,
                                in: currentProject,
                                context: modelContext
                            )
                            try? modelContext.save()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var currentProject: WorkspaceProject? {
        guard let id = selection.selectedProjectID else { return nil }
        return allProjects.first { $0.id == id }
    }

    private func status(for project: WorkspaceProject) -> RowStatus? {
        project.hasUnviewedActivity ? .done : nil
    }

    private func status(for agent: Agent) -> RowStatus? {
        agent.hasUnviewedActivity ? .done : nil
    }

    private func archive(_ project: WorkspaceProject) {
        project.archived = true
        if selection.selectedProjectID == project.id {
            selection.selectedProjectID = visibleProjects
                .first { $0.id != project.id && !$0.archived }?
                .id
                ?? allProjects.first { !$0.archived && !$0.isHiddenFromSidebar && $0.id != project.id }?
                .id
            selection.selectedAgentID = nil
            selection.showChat()
        }
        try? modelContext.save()
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

    private func filterChip(
        title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.accentText : Theme.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(selected ? Theme.chipBackground : Color.clear)
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    selected ? Theme.borderStructural : Color.clear,
                                    lineWidth: 1
                                )
                        )
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
            .accessibilityLabel(
                "Pane shortcuts: Command 1 Sidebar, Command 2 Chat, Command 3 Files, Command 4 Terminal"
            )
    }

    private func hint(_ keys: String) -> Text {
        Text(keys)
            .font(.system(size: 10).monospaced())
            .foregroundStyle(Theme.textTertiary)
    }
}

// MARK: - Rename sheet

private struct RenameProjectSheet: View {
    @Binding var name: String
    var isQuickChat: Bool
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isQuickChat ? "Name this Project" : "Rename Project")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            if isQuickChat {
                Text("Quick Chat projects stay hidden until you give them a name.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }

            TextField("Project name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.elevatedSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Theme.borderStructural, lineWidth: 1)
                        )
                )

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                Button("Save", action: onSave)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textOnAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Theme.accent)
                    )
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(Theme.appBackground)
    }
}

// Identifiable for sheet(item:) — `id` already lives on the model.
extension WorkspaceProject: Identifiable {}

// MARK: - Row chrome (shared by Projects + Agents lists)

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
    let selection = WorkspaceSelection()
    return SidebarView(selection: selection)
        .frame(width: 224, height: 600)
        .preferredColorScheme(.dark)
        .modelContainer(for: [
            WorkspaceProject.self,
            Agent.self,
            ChatThread.self,
            Message.self,
        ], inMemory: true)
}

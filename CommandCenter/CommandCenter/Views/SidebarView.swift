import SwiftData
import SwiftUI

/// Left sidebar: single flush column (sc1) — Projects / Workspaces / Agents /
/// Settings stacked edge-to-edge with hairline dividers, not floating glass cards.
///
/// T3: SwiftData-backed lists. T11: creation sheets. T12: archive filter + action.
/// T17: status-dot a11y labels + keyboard-reachable Archive.
/// Projects and Workspaces are collapsible sections with identical behavior.
struct SidebarView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var selection: WorkspaceSelection
    /// Optional: when present, amber Streaming dots track live turns (T17).
    var chat: ChatController? = nil

    var isFocused: Bool = false

    /// T12: default shows active containers; toggle reveals archived.
    @State private var showArchived = false
    @State private var creationKind: WorkspaceContainerKind?
    @State private var showAgentSheet = false
    @State private var showSettings = false
    @State private var renameTarget: WorkspaceProject?
    @State private var renameText = ""
    /// Top (Projects + Workspaces) fraction of free height vs Agents.
    // Key bumped so sc1 default wins over the old 0.55 store.
    @AppStorage("prodigy.sidebar.projectsFraction.v2")
    private var projectsFraction = LayoutMetrics.sidebarProjectsDefaultFraction
    @AppStorage("prodigy.sidebar.projectsExpanded")
    private var projectsExpanded = true
    @AppStorage("prodigy.sidebar.workspacesExpanded")
    private var workspacesExpanded = true

    @Query(sort: \WorkspaceProject.lastActiveAt, order: .reverse)
    private var allProjects: [WorkspaceProject]

    @Query(sort: \Agent.name, order: .forward)
    private var agents: [Agent]

    private var visibleProjects: [WorkspaceProject] {
        visibleContainers(kind: .project)
    }

    private var visibleWorkspaces: [WorkspaceProject] {
        visibleContainers(kind: .workspace)
    }

    private func visibleContainers(kind: WorkspaceContainerKind) -> [WorkspaceProject] {
        allProjects.filter { project in
            guard project.kind == kind else { return false }
            guard !project.isHiddenFromSidebar else { return false }
            return showArchived ? project.archived : !project.archived
        }
    }

    var body: some View {
        // Continuous column: Dashboard + Projects/Workspaces | Agents | Settings.
        VStack(spacing: 0) {
            dashboardRow
                .padding(.top, 8)
                .padding(.bottom, 4)

            ResizableVStack(
                topFraction: $projectsFraction,
                minTop: LayoutMetrics.nestedPaneMinHeight,
                minBottom: LayoutMetrics.nestedPaneMinHeight,
                maxTopFraction: LayoutMetrics.nestedPaneMaxFraction,
                maxBottomFraction: LayoutMetrics.nestedPaneMaxFraction,
                gap: LiquidGlassMetrics.columnDividerWidth,
                tooltip: "Drag to resize Projects/Workspaces and Agents"
            ) {
                containersColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } bottom: {
                agentsSection
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle()
                .fill(Theme.borderHairline)
                .frame(height: 1)

            settingsCard
                .frame(height: LayoutMetrics.settingsCardHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.sidebarBackground)
        .sheet(item: $creationKind) { kind in
            ProjectCreationSheet(kind: kind) { project in
                selection.selectProject(project)
            }
        }
        .sheet(isPresented: $showAgentSheet) {
            AgentCreationSheet { agent in
                let project = currentProject
                selection.selectAgent(agent, in: project, context: modelContext)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .prodigyOpenSettings)) { _ in
            showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .prodigyCheckForUpdates)) { _ in
            showSettings = true
            Task { await AppUpdateService.shared.checkForUpdates(userInitiated: true) }
        }
        .sheet(item: $renameTarget) { project in
            RenameProjectSheet(
                name: $renameText,
                isQuickChat: project.isQuickChat || project.isHiddenFromSidebar,
                kind: project.kind
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

    // MARK: - Projects + Workspaces column

    private var containersColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Shared Active / Archived filter for both lists.
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
            .padding(.top, 6)
            .padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    collapsibleContainerSection(
                        kind: .project,
                        isExpanded: $projectsExpanded,
                        items: visibleProjects
                    )
                    collapsibleContainerSection(
                        kind: .workspace,
                        isExpanded: $workspacesExpanded,
                        items: visibleWorkspaces
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func collapsibleContainerSection(
        kind: WorkspaceContainerKind,
        isExpanded: Binding<Bool>,
        items: [WorkspaceProject]
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            collapsibleSectionHeader(
                title: kind.sectionTitle,
                isExpanded: isExpanded.wrappedValue,
                onToggle: { isExpanded.wrappedValue.toggle() },
                onAdd: { creationKind = kind }
            )

            if isExpanded.wrappedValue {
                if items.isEmpty {
                    emptyContainersHint(kind: kind)
                } else {
                    VStack(spacing: 0) {
                        ForEach(items, id: \.id) { project in
                            projectRow(project)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func collapsibleSectionHeader(
        title: String,
        isExpanded: Bool,
        onToggle: @escaping () -> Void,
        onAdd: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 4) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(AppTypography.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                        .accessibilityHidden(true)

                    Text(title)
                        .font(AppTypography.section)
                        .foregroundStyle(Theme.textSecondary)
                        .textCase(.uppercase)
                        .tracking(0.4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint(isExpanded ? "Collapse section" : "Expand section")
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            Spacer(minLength: 0)

            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(AppTypography.callout.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("New \(title.dropLast())")
            .accessibilityLabel("New \(title.dropLast())")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .animation(.easeInOut(duration: 0.15), value: isExpanded)
    }

    private func emptyContainersHint(kind: WorkspaceContainerKind) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                showArchived
                    ? "No archived \(kind.sectionTitle.lowercased())."
                    : kind == .project
                        ? "Group chats and files by what you're working on."
                        : "Same as projects — for long-lived work folders."
            )
            .font(AppTypography.secondary)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            if !showArchived {
                Button {
                    creationKind = kind
                } label: {
                    Text("New \(kind.singularTitle)")
                        .font(AppTypography.secondary.weight(.medium))
                }
                .buttonStyle(.glass)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Dashboard (sc3)

    private var dashboardRow: some View {
        let selected = selection.activeSurface == .dashboard
        return Button {
            selection.showDashboard()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.2x2")
                    .font(Font.callout.weight(.medium))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)

                Text("Dashboard")
                    .font((selected ? Font.callout.weight(.semibold) : Font.callout))
                    .foregroundStyle(Theme.textPrimary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Theme.selectionFill : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .accessibilityLabel("Dashboard")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("Project board (sc3)")
    }

    // MARK: - Settings

    private var settingsCard: some View {
        Button {
            showSettings = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "gearshape.fill")
                    .font(AppTypography.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)

                Text("Settings")
                    .font(AppTypography.callout)
                    .foregroundStyle(Theme.textPrimary)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(AppTypography.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
        .accessibilityHint("Opens appearance and app preferences")
    }

    // MARK: - Project / Workspace rows

    @ViewBuilder
    private func projectRow(_ project: WorkspaceProject) -> some View {
        HStack(spacing: 0) {
            SidebarRowView(
                title: project.name,
                icon: project.kind.systemImage,
                status: status(for: project),
                isSelected: selection.selectedProjectID == project.id
                    && selection.selectedAgentID == nil
            ) {
                selection.selectProject(project)
                try? modelContext.save()
            }

            // T17: Archive is a real Button — Tab-focusable, Space/Enter-activatable,
            // and focus-visible via the system keyboard focus ring. Context menu kept
            // as a secondary mouse path (and Ctrl-click / menu-key when available).
            archiveButton(for: project)
        }
        .contextMenu {
            if project.archived {
                Button("Unarchive") {
                    unarchive(project)
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

    /// Per-row Archive / Unarchive control (T12 + T17 keyboard reachability).
    private func archiveButton(for project: WorkspaceProject) -> some View {
        ProjectArchiveButton(
            projectName: project.name,
            isArchived: project.archived,
            kindLabel: project.kind.singularTitle.lowercased()
        ) {
            if project.archived {
                unarchive(project)
            } else {
                archive(project)
            }
        }
        .padding(.trailing, 6)
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
                        .font(AppTypography.secondary)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        showAgentSheet = true
                    } label: {
                        Text("New Agent")
                            .font(AppTypography.secondary.weight(.medium))
                    }
                    .buttonStyle(.glass)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                Spacer(minLength: 0)
            } else {
                ScrollView {
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    // MARK: - Helpers

    private var currentProject: WorkspaceProject? {
        guard let id = selection.selectedProjectID else { return nil }
        return allProjects.first { $0.id == id }
    }

    /// Busy (amber) > unread (green) > idle. Always a concrete status so the
    /// status-dot can announce Streaming / Idle to VoiceOver (T17).
    private func status(for project: WorkspaceProject) -> RowStatus {
        if let chat, chat.isBusy, chat.streamingProjectID == project.id {
            return .busy
        }
        if project.hasUnviewedActivity { return .done }
        return .idle
    }

    private func status(for agent: Agent) -> RowStatus {
        if let chat, chat.isBusy, let threadID = chat.streamingThreadID,
           agent.threads.contains(where: { $0.id == threadID }) {
            return .busy
        }
        if agent.hasUnviewedActivity { return .done }
        return .idle
    }

    private func archive(_ project: WorkspaceProject) {
        project.archived = true
        if selection.selectedProjectID == project.id {
            // Prefer another container of the same kind, then any active container.
            let sameKind = allProjects.first {
                $0.id != project.id
                    && $0.kind == project.kind
                    && !$0.archived
                    && !$0.isHiddenFromSidebar
            }
            let anyActive = allProjects.first {
                $0.id != project.id && !$0.archived && !$0.isHiddenFromSidebar
            }
            if let next = sameKind ?? anyActive {
                selection.selectProject(next)
            } else {
                selection.showDashboard()
            }
        }
        try? modelContext.save()
    }

    private func unarchive(_ project: WorkspaceProject) {
        project.archived = false
        try? modelContext.save()
    }

    private func sectionHeader(title: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(AppTypography.section)
                .foregroundStyle(Theme.textSecondary)
                .textCase(.uppercase)
                .tracking(0.4)

            Spacer()

            Button(action: action) {
                Image(systemName: "plus")
                    .font(AppTypography.callout.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("New \(title.dropLast())")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func filterChip(
        title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(selected ? AppTypography.caption.weight(.semibold) : AppTypography.caption)
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(selected ? Theme.chipBackground.opacity(0.85) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

}

// MARK: - Rename sheet

private struct RenameProjectSheet: View {
    @Binding var name: String
    var isQuickChat: Bool
    var kind: WorkspaceContainerKind = .project
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isQuickChat ? "Name this \(kind.singularTitle)" : "Rename \(kind.singularTitle)")
                .font(Font.headline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)

            if isQuickChat {
                Text("Quick Chat \(kind.sectionTitle.lowercased()) stay hidden until you give them a name.")
                    .font(Font.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }

            TextField("\(kind.singularTitle) name", text: $name)
                .textFieldStyle(.plain)
                .font(Font.callout)
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
                    .font(Font.callout.weight(.medium))
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

/// Sidebar activity indicator states (Visual System status dots + T17 a11y).
///
/// - `busy`: amber — actively streaming tokens
/// - `done`: green — unread completed activity
/// - `idle`: no color — not streaming / no unread (announced as "Idle")
enum RowStatus: Equatable {
    case busy
    case done
    case idle

    var color: Color? {
        switch self {
        case .busy: Theme.statusBusy
        case .done: Theme.statusDone
        case .idle: nil
        }
    }

    /// VoiceOver value — never color-only (T17 / PLAN Accessibility).
    var accessibilityValue: String {
        switch self {
        case .busy: "Streaming"
        case .done: "Unread activity"
        case .idle: "Idle"
        }
    }
}

/// Colored activity indicator with explicit accessibility label + value.
/// Color is supplementary; VoiceOver reads "Status, Streaming" / "Status, Idle".
struct StatusDot: View {
    let status: RowStatus

    var body: some View {
        ZStack {
            if let color = status.color {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            } else {
                // Reserve the same slot so row layout is stable; a11y still announces Idle.
                Color.clear
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status")
        .accessibilityValue(status.accessibilityValue)
        // Decorative color alone must not be the only channel (WCAG / PLAN T17).
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Per-row Archive / Unarchive control.
///
/// Real `Button` so it is Tab-reachable and Space/Enter-activatable under macOS
/// Full Keyboard Access. Draws an explicit focus ring because `.plain` would
/// otherwise leave focus invisible (T17).
struct ProjectArchiveButton: View {
    let projectName: String
    let isArchived: Bool
    var kindLabel: String = "project"
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: isArchived ? "tray.and.arrow.up" : "archivebox")
                .font(Font.caption.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isFocused ? Theme.selectionFill : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .help(isArchived ? "Unarchive" : "Archive")
        .accessibilityLabel(isArchived ? "Unarchive \(projectName)" : "Archive \(projectName)")
        .accessibilityHint(
            isArchived
                ? "Moves this \(kindLabel) back to the active list"
                : "Hides this \(kindLabel) from the active list"
        )
        .accessibilityAddTraits(.isButton)
    }
}

struct SidebarRowView: View {
    let title: String
    let icon: String
    var status: RowStatus = .idle
    var isSelected: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(AppTypography.callout)
                    .frame(width: 15)
                    .opacity(0.8)
                    .accessibilityHidden(true)

                Text(title)
                    .font(AppTypography.callout)
                    .lineLimit(1)

                Spacer(minLength: 4)

                // StatusDot keeps its own a11y label/value so VoiceOver can
                // announce Streaming / Idle independently of the row name (T17).
                StatusDot(status: status)
            }
            // Soft selection chip (sc2) is light gray — use label color, not
            // textOnAccent (white), or rows go white-on-light in Light mode.
            .foregroundStyle(Theme.textPrimary)
            .fontWeight(isSelected ? .medium : .regular)
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
        .padding(.leading, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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

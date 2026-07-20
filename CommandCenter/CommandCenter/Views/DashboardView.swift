import SwiftData
import SwiftUI

// MARK: - Dashboard (sc3)

/// Light/dark project board matching Desktop `sc3.png`.
///
/// Columns map existing Project state (no extra schema in V1):
/// - **Backlog** — quick-chat / never-promoted or empty-history projects
/// - **In progress** — active sidebar projects
/// - **In review** — unread activity (`hasUnviewedActivity`)
/// - **Done** — archived
struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var selection: WorkspaceSelection
    var onCreateProject: () -> Void

    @Query(sort: \WorkspaceProject.lastActiveAt, order: .reverse)
    private var allProjects: [WorkspaceProject]

    private var backlog: [WorkspaceProject] {
        allProjects.filter { project in
            guard !project.archived else { return false }
            if project.isQuickChat || project.isHiddenFromSidebar { return true }
            // No real conversation yet.
            let msgs = project.primaryThread?.messages.count ?? 0
            return msgs == 0
        }
    }

    private var inProgress: [WorkspaceProject] {
        allProjects.filter { project in
            guard !project.archived, !project.hasUnviewedActivity else { return false }
            if project.isQuickChat || project.isHiddenFromSidebar { return false }
            let msgs = project.primaryThread?.messages.count ?? 0
            return msgs > 0
        }
    }

    private var inReview: [WorkspaceProject] {
        allProjects.filter { !$0.archived && $0.hasUnviewedActivity }
    }

    private var done: [WorkspaceProject] {
        allProjects.filter(\.archived)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            filterChips
            board
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.centerBackground)
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            Text("Dashboard")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button {
                onCreateProject()
            } label: {
                Label("New Project", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.borderHairline)
                .frame(height: 1)
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All projects", selected: true)
                ForEach(uniqueFolderLabels.prefix(6), id: \.self) { label in
                    chip(label, selected: false)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.borderHairline.opacity(0.6))
                .frame(height: 1)
        }
    }

    private var uniqueFolderLabels: [String] {
        var seen = Set<String>()
        var labels: [String] = []
        for p in allProjects where !p.archived {
            let name = URL(fileURLWithPath: p.folderPath).lastPathComponent
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            labels.append(name)
        }
        return labels
    }

    private func chip(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(selected ? Theme.chipBackground : Color.clear)
            )
            .overlay(alignment: .bottom) {
                if selected {
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(height: 2)
                        .padding(.horizontal, 4)
                        .offset(y: 6)
                }
            }
    }

    // MARK: - Board

    private var board: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 16) {
                column(
                    title: "Backlog",
                    count: backlog.count,
                    icon: "circle",
                    tint: Theme.textTertiary,
                    projects: backlog
                )
                column(
                    title: "In progress",
                    count: inProgress.count,
                    icon: "circle.fill",
                    tint: Theme.statusBusy,
                    projects: inProgress
                )
                column(
                    title: "In review",
                    count: inReview.count,
                    icon: "checkmark.circle.fill",
                    tint: Theme.statusDone,
                    projects: inReview
                )
                column(
                    title: "Done",
                    count: done.count,
                    icon: "checkmark.circle",
                    tint: Theme.textSecondary,
                    projects: done
                )
            }
            .padding(20)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func column(
        title: String,
        count: Int,
        icon: String,
        tint: Color,
        projects: [WorkspaceProject]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(count)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 0)
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(projects, id: \.id) { project in
                        DashboardCard(project: project) {
                            open(project)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 280, alignment: .topLeading)
    }

    private func open(_ project: WorkspaceProject) {
        selection.selectProject(project)
        try? modelContext.save()
    }
}

// MARK: - Card

private struct DashboardCard: View {
    let project: WorkspaceProject
    let onOpen: () -> Void

    private var preview: String {
        let messages = project.primaryThread?.sortedMessages ?? []
        if let last = messages.last(where: { $0.role == .assistant || $0.role == .user }) {
            return last.content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return project.folderPath
    }

    private var slug: String {
        project.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Text(slug)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    statusGlyph
                }

                Text(project.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(preview)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                HStack {
                    Spacer()
                    Text(relativeTime(project.lastActiveAt))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.elevatedSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Theme.borderHairline, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(project.name)")
    }

    @ViewBuilder
    private var statusGlyph: some View {
        if project.hasUnviewedActivity {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.statusDone)
        } else if project.archived {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        } else {
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(Theme.statusBusy)
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        if seconds < 86_400 * 14 { return "\(seconds / 86_400)d ago" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }
}

#Preview("Dashboard") {
    DashboardView(selection: WorkspaceSelection(), onCreateProject: {})
        .frame(width: 960, height: 640)
        .modelContainer(for: [
            WorkspaceProject.self,
            Agent.self,
            ChatThread.self,
            Message.self,
        ], inMemory: true)
}

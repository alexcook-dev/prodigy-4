import Foundation
import SwiftData

/// Top-level work container: owns a working folder, one V1 chat thread, and
/// optional per-Agent conversation threads scoped to this Project.
///
/// Named `WorkspaceProject` in code only to avoid clashing with Xcode's
/// `Project` type; PLAN.md and the UI call this a Project.
@Model
final class WorkspaceProject {
    var id: UUID
    var name: String
    /// Absolute path used as CLI `cwd` and file-browser root.
    var folderPath: String
    /// Soft-delete / hide-from-default-list (T12). Scoped to Projects only.
    var archived: Bool
    /// Updated on selection; T14 uses this for launch resume.
    var lastActiveAt: Date
    /// Green status-dot: unread completed activity until the chat tab is opened.
    var hasUnviewedActivity: Bool
    /// Quick-chat Projects start hidden from the sidebar until renamed/promoted (T11).
    var isHiddenFromSidebar: Bool
    /// True when created via the "quick chat" entry point (initially unlabeled).
    var isQuickChat: Bool
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ChatThread.project)
    var threads: [ChatThread] = []

    init(
        name: String,
        folderPath: String,
        archived: Bool = false,
        lastActiveAt: Date = .now,
        hasUnviewedActivity: Bool = false,
        isHiddenFromSidebar: Bool = false,
        isQuickChat: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = UUID()
        self.name = name
        self.folderPath = folderPath
        self.archived = archived
        self.lastActiveAt = lastActiveAt
        self.hasUnviewedActivity = hasUnviewedActivity
        self.isHiddenFromSidebar = isHiddenFromSidebar
        self.isQuickChat = isQuickChat
        self.createdAt = createdAt
    }

    /// V1: the single primary (non-Agent) chat thread for this Project.
    var primaryThread: ChatThread? {
        threads.first { $0.agent == nil }
    }

    /// Thread for conversing with a specific Agent inside this Project, if any.
    func thread(for agent: Agent) -> ChatThread? {
        threads.first { $0.agent?.id == agent.id }
    }
}

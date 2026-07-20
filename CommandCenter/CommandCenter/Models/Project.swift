import Foundation
import SwiftData

/// Sidebar list kind: **Projects** and **Workspaces** are the same container
/// type with identical behavior — only which collapsible section they appear in.
enum WorkspaceContainerKind: String, Codable, CaseIterable, Identifiable {
    case project
    case workspace

    var id: String { rawValue }

    var sectionTitle: String {
        switch self {
        case .project: return "Projects"
        case .workspace: return "Workspaces"
        }
    }

    var singularTitle: String {
        switch self {
        case .project: return "Project"
        case .workspace: return "Workspace"
        }
    }

    var defaultFolderParentName: String {
        switch self {
        case .project: return "Projects"
        case .workspace: return "Workspaces"
        }
    }

    var systemImage: String {
        switch self {
        case .project: return "square.on.square"
        case .workspace: return "shippingbox"
        }
    }
}

/// Top-level work container: owns a working folder, one V1 chat thread, and
/// optional per-Agent conversation threads scoped to this Project/Workspace.
///
/// Named `WorkspaceProject` in code only to avoid clashing with Xcode's
/// `Project` type; the UI labels items as Project or Workspace via `kind`.
@Model
final class WorkspaceProject {
    var id: UUID
    var name: String
    /// Absolute path used as CLI `cwd` and file-browser root.
    var folderPath: String
    /// Soft-delete / hide-from-default-list (T12).
    var archived: Bool
    /// Updated on selection; T14 uses this for launch resume.
    var lastActiveAt: Date
    /// Green status-dot: unread completed activity until the chat tab is opened.
    var hasUnviewedActivity: Bool
    /// Quick-chat Projects start hidden from the sidebar until renamed/promoted (T11).
    var isHiddenFromSidebar: Bool
    /// True when created via the "quick chat" entry point (initially unlabeled).
    var isQuickChat: Bool
    /// `WorkspaceContainerKind.rawValue` — `"project"` or `"workspace"`.
    /// Defaults to project for existing SwiftData rows (nil-safe via `kind`).
    var kindRaw: String?
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
        kind: WorkspaceContainerKind = .project,
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
        self.kindRaw = kind.rawValue
        self.createdAt = createdAt
    }

    /// Sidebar section this container belongs to (legacy rows → project).
    var kind: WorkspaceContainerKind {
        get {
            guard let kindRaw, let value = WorkspaceContainerKind(rawValue: kindRaw) else {
                return .project
            }
            return value
        }
        set { kindRaw = newValue.rawValue }
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

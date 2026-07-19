import Foundation
import SwiftData
import SwiftUI

/// Center-pane surface: the active chat thread, or a file-preview tab.
/// V1: tab bar "+" only ever opens file previews — never a second chat thread.
enum CenterSurface: Hashable, Identifiable {
    case chat
    case filePreview(FilePreviewTab)

    var id: String {
        switch self {
        case .chat: "chat"
        case .filePreview(let tab): tab.id.uuidString
        }
    }
}

struct FilePreviewTab: Hashable, Identifiable {
    let id: UUID
    var fileName: String
    var filePath: String

    init(id: UUID = UUID(), fileName: String, filePath: String) {
        self.id = id
        self.fileName = fileName
        self.filePath = filePath
    }
}

/// Shared selection state for sidebar + center pane.
/// Held by `WorkspaceRootView` and passed down as bindings / environment.
@Observable
final class WorkspaceSelection {
    var selectedProjectID: UUID?
    var selectedAgentID: UUID?
    /// Active center surface (chat or a file-preview tab).
    var activeSurface: CenterSurface = .chat
    /// Open file-preview tabs only — never extra chat threads (T11).
    var filePreviewTabs: [FilePreviewTab] = []

    func selectProject(_ project: WorkspaceProject) {
        selectedProjectID = project.id
        selectedAgentID = nil
        project.lastActiveAt = .now
        project.hasUnviewedActivity = false
        activeSurface = .chat
    }

    func selectAgent(_ agent: Agent, in project: WorkspaceProject?, context: ModelContext) {
        selectedAgentID = agent.id
        agent.lastActiveAt = .now
        agent.hasUnviewedActivity = false
        // Agent selection does not clear Project — persona is cross-project.
        // Conversation history is still scoped to the active Project.
        if let project {
            _ = AgentFactory.thread(for: agent, in: project, context: context)
        }
        activeSurface = .chat
    }

    /// Tab bar "+" — file previews only. Never creates a second chat thread.
    func openFilePreview(fileName: String, filePath: String) {
        let tab = FilePreviewTab(fileName: fileName, filePath: filePath)
        filePreviewTabs.append(tab)
        activeSurface = .filePreview(tab)
    }

    func closeFilePreview(_ tab: FilePreviewTab) {
        filePreviewTabs.removeAll { $0.id == tab.id }
        if case .filePreview(let open) = activeSurface, open.id == tab.id {
            activeSurface = .chat
        }
    }

    func showChat() {
        activeSurface = .chat
    }
}

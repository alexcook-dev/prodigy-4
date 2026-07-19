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

    var url: URL { URL(fileURLWithPath: filePath) }
}

/// Shared selection state for sidebar + center pane.
/// Held by `WorkspaceRootView` and passed down as bindings / environment.
/// Also hosts file-preview presentation for the file browser (T6 + Wave 3 wiring).
@MainActor
@Observable
final class WorkspaceSelection: FilePreviewPresenting {
    var selectedProjectID: UUID?
    var selectedAgentID: UUID?
    /// Active center surface (chat or a file-preview tab).
    var activeSurface: CenterSurface = .chat
    /// Open file-preview tabs only — never extra chat threads (T11).
    var filePreviewTabs: [FilePreviewTab] = []
    /// Staged by ⌘⏎ "Discuss in chat"; `CenterPaneView` drains into the composer.
    var pendingComposerInsert: String?

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
        if let existing = filePreviewTabs.first(where: { $0.filePath == filePath }) {
            activeSurface = .filePreview(existing)
            return
        }
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

    /// Unconditional "go to Chat tab" (⌘2). Preview tabs stay open in the background.
    func showChat() {
        activeSurface = .chat
    }

    // MARK: FilePreviewPresenting (file browser → center pane)

    /// File-tree selection flips the center pane into preview mode (Next Step 4).
    func presentFilePreview(_ request: FilePreviewRequest) {
        openFilePreview(fileName: request.fileName, filePath: request.url.path)
    }

    func dismissFilePreview(id: FilePreviewRequest.ID) {
        if let tab = filePreviewTabs.first(where: { $0.filePath == id.path }) {
            closeFilePreview(tab)
        }
    }

    func activateChatTab() {
        showChat()
    }

    /// ⌘⏎ from a file preview: switch to chat and stage a lightweight path
    /// reference for the composer (plain text, user-editable — not auto-send).
    func discussInChat(_ request: FilePreviewRequest) {
        activateChatTab()
        pendingComposerInsert = Self.composerReference(for: request)
    }

    /// Plain-text file reference: path, plus `:line` / `:start-end` when known.
    static func composerReference(for request: FilePreviewRequest) -> String {
        var path = request.url.path
        if let range = request.lineRange {
            if range.lowerBound == range.upperBound {
                path += ":\(range.lowerBound)"
            } else {
                path += ":\(range.lowerBound)-\(range.upperBound)"
            }
        }
        return "Regarding `\(path)`:"
    }
}

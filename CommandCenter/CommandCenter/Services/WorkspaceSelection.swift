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
/// Also hosts file-preview presentation for the file browser (T6).
@MainActor
@Observable
final class WorkspaceSelection: FilePreviewPresenting {
    var selectedProjectID: UUID?
    var selectedAgentID: UUID?
    /// Active center surface (chat or a file-preview tab).
    var activeSurface: CenterSurface = .chat
    /// Open file-preview tabs only — never extra chat threads (T11).
    var filePreviewTabs: [FilePreviewTab] = []
    /// Set once launch auto-resume (T14) has run for this session. Prevents
    /// re-warming the CLI process on every incidental `onChange`.
    private(set) var didPerformLaunchResume = false

    /// Mark launch resume complete without changing selection (e.g. when the
    /// user already selected a Project via the creation sheet before the
    /// `allProjects` count change fired).
    func markLaunchResumeComplete() {
        didPerformLaunchResume = true
    }

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
        // Still bump the Project's lastActiveAt so launch resume (T14) returns
        // here after quit, not to a different Project the user left earlier.
        if let project {
            project.lastActiveAt = .now
            _ = AgentFactory.thread(for: agent, in: project, context: context)
        }
        activeSurface = .chat
    }

    // MARK: - Launch resume (T14 / design review D6)

    /// Auto-select the most-recently-active Project and its most recent thread.
    ///
    /// - Returns `nil` only for true first-run (zero Projects ever) — callers
    ///   leave selection empty so `FirstRunView` (wf-2) is shown.
    /// - Never presents a picker: any existing Project (including hidden quick-
    ///   chat) is restored by `lastActiveAt`. Non-archived win over archived
    ///   when both exist; among equals, the SwiftData query order (desc
    ///   `lastActiveAt`) decides.
    /// - Thread choice is by `updatedAt` (V1 usually one primary thread; Agent
    ///   threads may be more recent if the user left mid-Agent conversation).
    @discardableResult
    func resumeLastActive(
        from projects: [WorkspaceProject]
    ) -> (project: WorkspaceProject, thread: ChatThread?)? {
        guard !projects.isEmpty else {
            selectedProjectID = nil
            selectedAgentID = nil
            return nil
        }

        // Prefer non-archived (incl. hidden quick-chat); fall back to archived
        // so a store that only has archived Projects still skips the picker.
        let project = projects.first(where: { !$0.archived }) ?? projects[0]

        let thread = Self.mostRecentThread(in: project)

        selectProject(project)

        if let thread, let agent = thread.agent {
            // Restore Agent-scoped conversation without re-creating the thread.
            selectedAgentID = agent.id
            agent.lastActiveAt = .now
            agent.hasUnviewedActivity = false
        }

        showChat()
        didPerformLaunchResume = true
        return (project, thread)
    }

    /// Most recently touched thread in a Project (primary or Agent-scoped).
    static func mostRecentThread(in project: WorkspaceProject) -> ChatThread? {
        if let newest = project.threads.max(by: { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt < rhs.updatedAt
            }
            // Tie-break: prefer the primary (agent-less) V1 chat.
            return (lhs.agent != nil) && (rhs.agent == nil)
        }) {
            return newest
        }
        return project.primaryThread
    }

    /// Warm the Claude CLI process for a restored thread via D5.3 `--resume`.
    func prepareSessionResume(
        project: WorkspaceProject,
        thread: ChatThread?,
        provider: ClaudeCLIProvider = .shared
    ) {
        guard let thread else {
            provider.setFocusedProject(project.id)
            return
        }
        let systemPrompt: String
        if let agent = thread.agent {
            let persona = agent.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            systemPrompt = persona.isEmpty
                ? ClaudeCLIDefaults.generalAssistantSystemPrompt
                : persona
        } else {
            systemPrompt = ClaudeCLIDefaults.generalAssistantSystemPrompt
        }
        provider.prepareLaunchResume(
            projectID: project.id,
            workingDirectory: project.folderPath,
            sessionID: thread.cliSessionID,
            systemPrompt: systemPrompt
        )
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

    func showChat() {
        activeSurface = .chat
    }

    // MARK: FilePreviewPresenting (file browser → center pane)

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

    func discussInChat(_ request: FilePreviewRequest) {
        // Switch to chat so the gesture feels right even before the composer exists.
        activateChatTab()
        // TODO(Wave 3 / T5): insert a plain-text reference into the composer.
        _ = request
    }
}

import Foundation
import SwiftData
import SwiftUI

/// Center-pane surface: chat, file preview, in-app browser, or Dashboard (sc3).
enum CenterSurface: Hashable, Identifiable {
    case chat
    case dashboard
    case filePreview(FilePreviewTab)
    case browser(BrowserTab)

    var id: String {
        switch self {
        case .chat: "chat"
        case .dashboard: "dashboard"
        case .filePreview(let tab): tab.id.uuidString
        case .browser(let tab): tab.id.uuidString
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

/// In-app browser tab (Safari-style WKWebView — sc8 / user request).
struct BrowserTab: Hashable, Identifiable {
    let id: UUID
    var title: String
    var urlString: String

    init(id: UUID = UUID(), title: String = "Safari", urlString: String = "https://www.apple.com") {
        self.id = id
        self.title = title
        self.urlString = urlString
    }
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
    /// In-app Safari browser tabs.
    var browserTabs: [BrowserTab] = []
    /// Set once launch auto-resume (T14) has run for this session.
    private(set) var didPerformLaunchResume = false

    func markLaunchResumeComplete() {
        didPerformLaunchResume = true
    }
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
            project.lastActiveAt = .now
            _ = AgentFactory.thread(for: agent, in: project, context: context)
        }
        activeSurface = .chat
    }


    // MARK: - Launch resume (T14 / design review D6)

    /// Auto-select the most-recently-active Project and its most recent thread.
    @discardableResult
    func resumeLastActive(
        from projects: [WorkspaceProject]
    ) -> (project: WorkspaceProject, thread: ChatThread?)? {
        guard !projects.isEmpty else {
            selectedProjectID = nil
            selectedAgentID = nil
            return nil
        }
        let project = projects.first(where: { !$0.archived }) ?? projects[0]
        let thread = Self.mostRecentThread(in: project)
        selectProject(project)
        if let thread, let agent = thread.agent {
            selectedAgentID = agent.id
            agent.lastActiveAt = .now
            agent.hasUnviewedActivity = false
        }
        showChat()
        didPerformLaunchResume = true
        return (project, thread)
    }

    static func mostRecentThread(in project: WorkspaceProject) -> ChatThread? {
        if let newest = project.threads.max(by: { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt < rhs.updatedAt
            }
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

    /// Unconditional "go to Chat tab" (⌘2). Preview tabs stay open in the background.
    func showChat() {
        activeSurface = .chat
    }

    /// sc3 Dashboard — project board over the center column (files/terminal stay).
    func showDashboard() {
        selectedProjectID = nil
        selectedAgentID = nil
        activeSurface = .dashboard
    }

    /// Open a new in-app Safari tab (WKWebView) in the center column.
    @discardableResult
    func openSafariTab(urlString: String = "https://www.apple.com") -> BrowserTab {
        let tab = BrowserTab(title: "Safari", urlString: urlString)
        browserTabs.append(tab)
        activeSurface = .browser(tab)
        return tab
    }

    func closeBrowserTab(_ tab: BrowserTab) {
        browserTabs.removeAll { $0.id == tab.id }
        if case .browser(let open) = activeSurface, open.id == tab.id {
            activeSurface = .chat
        }
    }

    func updateBrowserTab(_ tab: BrowserTab, title: String? = nil, urlString: String? = nil) {
        guard let idx = browserTabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if let title { browserTabs[idx].title = title }
        if let urlString { browserTabs[idx].urlString = urlString }
        if case .browser(let open) = activeSurface, open.id == tab.id {
            activeSurface = .browser(browserTabs[idx])
        }
    }

    /// Absolute path for "open with" / copy path — project folder or home.
    func workspacePath(from projects: [WorkspaceProject]) -> String {
        if let id = selectedProjectID,
           let project = projects.first(where: { $0.id == id }),
           !project.isQuickChat {
            return project.folderPath
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
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

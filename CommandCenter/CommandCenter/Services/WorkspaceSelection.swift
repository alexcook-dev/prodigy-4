import Foundation
import SwiftData
import SwiftUI

/// Center-pane surface: chat thread(s), file preview, in-app browser, or Dashboard.
///
/// Chat and browser surfaces use **only a UUID** so title/metadata updates do not
/// remount content or flip selection mid-interaction.
enum CenterSurface: Hashable, Identifiable {
    /// No center tabs open.
    case empty
    /// A specific open chat thread (tab id == `ChatThread.id`).
    case chat(UUID)
    case dashboard
    case filePreview(FilePreviewTab)
    case browser(UUID)
    /// In-app terminal session tab (PTY shell) — same column as Chat/Safari.
    case terminal(UUID)
    /// Apple Mail inbox viewer (via Mail.app scripting) — in-app.
    case appleMail
    /// Apple Calendar events (EventKit) — in-app.
    case appleCalendar

    var id: String {
        switch self {
        case .empty: "empty"
        case .chat(let threadID): "chat-\(threadID.uuidString)"
        case .dashboard: "dashboard"
        case .filePreview(let tab): tab.id.uuidString
        case .browser(let tabID): tabID.uuidString
        case .terminal(let tabID): "term-\(tabID.uuidString)"
        case .appleMail: "apple-mail"
        case .appleCalendar: "apple-calendar"
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

/// Open chat tab in the center tab bar (one per `ChatThread`).
struct ChatTab: Hashable, Identifiable {
    /// Same as `ChatThread.id`.
    let id: UUID
    var title: String

    init(id: UUID, title: String = "Chat") {
        self.id = id
        self.title = title
    }
}

/// In-app browser tab (WKWebView — Safari-style).
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

/// In-app terminal tab (SwiftTerm PTY) in the center column.
struct TerminalTab: Hashable, Identifiable {
    let id: UUID
    var title: String
    /// Working directory for the shell (defaults to user home).
    var workingDirectory: String

    init(
        id: UUID = UUID(),
        title: String = "Terminal",
        workingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
    }
}

/// Preset destinations for in-app web tabs (+ menu / Open With).
enum WebTabPreset: String, CaseIterable, Identifiable {
    case safari

    var id: String { rawValue }

    var title: String {
        switch self {
        case .safari: return "Safari"
        }
    }

    var urlString: String {
        switch self {
        case .safari: return "https://www.apple.com"
        }
    }

    var systemImage: String {
        switch self {
        case .safari: return "safari"
        }
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
    /// Active center surface (chat thread, Safari, file preview, or empty).
    var activeSurface: CenterSurface = .empty
    /// Open chat tabs (multiple threads). Closable; re-open / new via + menu / ⌘2.
    var chatTabs: [ChatTab] = []
    /// Open file-preview tabs.
    var filePreviewTabs: [FilePreviewTab] = []
    /// In-app Safari browser tabs.
    var browserTabs: [BrowserTab] = []
    /// In-app terminal tabs (center column).
    var terminalTabs: [TerminalTab] = []
    /// Whether the Apple Mail tab is open.
    var isAppleMailTabOpen: Bool = false
    /// Whether the Apple Calendar tab is open.
    var isAppleCalendarTabOpen: Bool = false
    /// Set once launch auto-resume (T14) has run for this session.
    private(set) var didPerformLaunchResume = false

    func markLaunchResumeComplete() {
        didPerformLaunchResume = true
    }
    /// Staged by ⌘⏎ "Discuss in chat"; `CenterPaneView` drains into the composer.
    var pendingComposerInsert: String?

    var hasOpenChatTabs: Bool { !chatTabs.isEmpty }

    var activeChatThreadID: UUID? {
        if case .chat(let id) = activeSurface { return id }
        return nil
    }

    func selectProject(_ project: WorkspaceProject) {
        selectedProjectID = project.id
        selectedAgentID = nil
        project.lastActiveAt = .now
        project.hasUnviewedActivity = false
        // Chat tabs are project-scoped — reset when switching projects.
        chatTabs = []
        if let thread = project.primaryThread ?? project.threads.first {
            openChatTab(thread: thread)
        } else if browserTabs.isEmpty && filePreviewTabs.isEmpty {
            activeSurface = .empty
        }
    }

    func selectAgent(_ agent: Agent, in project: WorkspaceProject?, context: ModelContext) {
        selectedAgentID = agent.id
        agent.lastActiveAt = .now
        agent.hasUnviewedActivity = false
        // Agent selection does not clear Project — persona is cross-project.
        // Conversation history is still scoped to the active Project.
        if let project {
            project.lastActiveAt = .now
            let thread = AgentFactory.thread(for: agent, in: project, context: context)
            openChatTab(thread: thread)
        } else {
            showChat()
        }
    }

    /// Pick the best surface after closing a tab (or empty if none remain).
    private func fallBackSurfaceAfterClose() -> CenterSurface {
        if let chat = chatTabs.last {
            return .chat(chat.id)
        }
        if isAppleMailTabOpen {
            return .appleMail
        }
        if isAppleCalendarTabOpen {
            return .appleCalendar
        }
        if let browser = browserTabs.last {
            return .browser(browser.id)
        }
        if let terminal = terminalTabs.last {
            return .terminal(terminal.id)
        }
        if let preview = filePreviewTabs.last {
            return .filePreview(preview)
        }
        return .empty
    }

    /// Whether the active center surface is a closable tab (⌘W).
    var canCloseActiveTab: Bool {
        switch activeSurface {
        case .chat, .filePreview, .browser, .terminal, .appleMail, .appleCalendar:
            return true
        case .empty, .dashboard:
            return false
        }
    }

    /// Close the currently active center tab (⌘W). No-op when empty/dashboard.
    @discardableResult
    func closeActiveTab() -> Bool {
        switch activeSurface {
        case .chat(let id):
            closeChatTab(id: id)
            return true
        case .filePreview(let tab):
            closeFilePreview(id: tab.id)
            return true
        case .browser(let id):
            closeBrowserTab(id: id)
            return true
        case .terminal(let id):
            closeTerminalTab(id: id)
            return true
        case .appleMail:
            closeAppleMailTab()
            return true
        case .appleCalendar:
            closeAppleCalendarTab()
            return true
        case .empty, .dashboard:
            return false
        }
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
            chatTabs = []
            activeSurface = .empty
            return nil
        }
        let project = projects.first(where: { !$0.archived }) ?? projects[0]
        let thread = Self.mostRecentThread(in: project)
        selectProject(project)
        if let thread {
            if let agent = thread.agent {
                selectedAgentID = agent.id
                agent.lastActiveAt = .now
                agent.hasUnviewedActivity = false
            }
            openChatTab(thread: thread)
        }
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

    // MARK: - Chat tabs (multiple)

    /// Focus the active/last chat tab if any are open (does not create threads).
    func showChat() {
        if case .chat(let id) = activeSurface, chatTabs.contains(where: { $0.id == id }) {
            return
        }
        if let last = chatTabs.last {
            activeSurface = .chat(last.id)
        }
    }

    /// Open an existing thread as a tab (or focus it if already open).
    @discardableResult
    func openChatTab(thread: ChatThread) -> ChatTab {
        let title = Self.displayTitle(for: thread)
        if let idx = chatTabs.firstIndex(where: { $0.id == thread.id }) {
            if chatTabs[idx].title != title {
                chatTabs[idx].title = title
            }
            activeSurface = .chat(thread.id)
            if thread.agent == nil {
                selectedAgentID = nil
            } else if let agentID = thread.agent?.id {
                selectedAgentID = agentID
            }
            return chatTabs[idx]
        }
        let tab = ChatTab(id: thread.id, title: title)
        chatTabs.append(tab)
        if thread.agent == nil {
            selectedAgentID = nil
        } else if let agentID = thread.agent?.id {
            selectedAgentID = agentID
        }
        activeSurface = .chat(thread.id)
        return tab
    }

    func selectChatTab(id: UUID) {
        guard chatTabs.contains(where: { $0.id == id }) else { return }
        activeSurface = .chat(id)
    }

    /// Close one chat tab. Thread + history stay in SwiftData.
    func closeChatTab(id: UUID) {
        chatTabs.removeAll { $0.id == id }
        if case .chat(let openID) = activeSurface, openID == id {
            activeSurface = fallBackSurfaceAfterClose()
        }
    }

    /// Create a brand-new general (non-agent) chat thread and open it as a tab.
    @discardableResult
    func openNewChatTab(
        in project: WorkspaceProject,
        context: ModelContext
    ) -> ChatThread {
        let thread = Self.makeGeneralChatThread(in: project, context: context)
        openChatTab(thread: thread)
        return thread
    }

    /// Focus last chat tab, or open primary / create one if none are open.
    @discardableResult
    func showOrCreateChat(
        in project: WorkspaceProject?,
        context: ModelContext
    ) -> ChatThread? {
        if let last = chatTabs.last {
            activeSurface = .chat(last.id)
            if let project,
               let thread = project.threads.first(where: { $0.id == last.id }) {
                return thread
            }
            return nil
        }
        guard let project else { return nil }
        if let primary = project.primaryThread {
            openChatTab(thread: primary)
            return primary
        }
        if let any = project.threads.first {
            openChatTab(thread: any)
            return any
        }
        return openNewChatTab(in: project, context: context)
    }

    func updateChatTabTitle(id: UUID, title: String) {
        guard let idx = chatTabs.firstIndex(where: { $0.id == id }) else { return }
        if chatTabs[idx].title != title {
            chatTabs[idx].title = title
        }
    }

    private static func displayTitle(for thread: ChatThread) -> String {
        let t = thread.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        if let agentName = thread.agent?.name, !agentName.isEmpty {
            return agentName
        }
        return "Chat"
    }

    /// Insert a new agent-less chat thread on the project.
    private static func makeGeneralChatThread(
        in project: WorkspaceProject,
        context: ModelContext
    ) -> ChatThread {
        let generalCount = project.threads.filter { $0.agent == nil }.count
        let title = generalCount == 0 ? "Chat" : "Chat \(generalCount + 1)"
        let thread = ChatThread(title: title, project: project)
        context.insert(thread)
        try? context.save()
        return thread
    }

    // MARK: - File preview

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
        closeFilePreview(id: tab.id)
    }

    func closeFilePreview(id: UUID) {
        filePreviewTabs.removeAll { $0.id == id }
        if case .filePreview(let open) = activeSurface, open.id == id {
            activeSurface = fallBackSurfaceAfterClose()
        }
    }

    /// sc3 Dashboard — project board over the center column (files/terminal stay).
    func showDashboard() {
        selectedProjectID = nil
        selectedAgentID = nil
        activeSurface = .dashboard
    }

    // MARK: - Browser

    /// Open a new in-app web tab (WKWebView) in the center column.
    @discardableResult
    func openWebTab(title: String, urlString: String) -> BrowserTab {
        let tab = BrowserTab(title: title, urlString: urlString)
        browserTabs.append(tab)
        activeSurface = .browser(tab.id)
        return tab
    }

    /// Open a preset web destination (Safari home, etc.).
    @discardableResult
    func openWebTab(_ preset: WebTabPreset) -> BrowserTab {
        openWebTab(title: preset.title, urlString: preset.urlString)
    }

    /// Open a new in-app Safari-style browser tab.
    @discardableResult
    func openSafariTab(urlString: String = WebTabPreset.safari.urlString) -> BrowserTab {
        openWebTab(title: "Safari", urlString: urlString)
    }

    // MARK: - Apple Mail / Calendar (in-app)

    func openAppleMailTab() {
        isAppleMailTabOpen = true
        activeSurface = .appleMail
    }

    func closeAppleMailTab() {
        isAppleMailTabOpen = false
        if case .appleMail = activeSurface {
            activeSurface = fallBackSurfaceAfterClose()
        }
    }

    func openAppleCalendarTab() {
        isAppleCalendarTabOpen = true
        activeSurface = .appleCalendar
    }

    func closeAppleCalendarTab() {
        isAppleCalendarTabOpen = false
        if case .appleCalendar = activeSurface {
            activeSurface = fallBackSurfaceAfterClose()
        }
    }

    func selectBrowserTab(_ tab: BrowserTab) {
        activeSurface = .browser(tab.id)
    }

    func closeBrowserTab(_ tab: BrowserTab) {
        closeBrowserTab(id: tab.id)
    }

    func closeBrowserTab(id: UUID) {
        browserTabs.removeAll { $0.id == id }
        if case .browser(let openID) = activeSurface, openID == id {
            activeSurface = fallBackSurfaceAfterClose()
        }
    }

    // MARK: - Center terminal tabs

    /// Open a new terminal tab in the center column (independent PTY session).
    @discardableResult
    func openTerminalTab(workingDirectory: String? = nil) -> TerminalTab {
        let cwd = workingDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let index = terminalTabs.count + 1
        let tab = TerminalTab(
            title: index == 1 ? "Terminal" : "Terminal \(index)",
            workingDirectory: cwd
        )
        terminalTabs.append(tab)
        activeSurface = .terminal(tab.id)
        return tab
    }

    func selectTerminalTab(_ tab: TerminalTab) {
        activeSurface = .terminal(tab.id)
    }

    func selectTerminalTab(id: UUID) {
        guard terminalTabs.contains(where: { $0.id == id }) else { return }
        activeSurface = .terminal(id)
    }

    func closeTerminalTab(_ tab: TerminalTab) {
        closeTerminalTab(id: tab.id)
    }

    func closeTerminalTab(id: UUID) {
        terminalTabs.removeAll { $0.id == id }
        if case .terminal(let openID) = activeSurface, openID == id {
            activeSurface = fallBackSurfaceAfterClose()
        }
    }

    func terminalTab(id: UUID) -> TerminalTab? {
        terminalTabs.first { $0.id == id }
    }

    func updateTerminalTab(id: UUID, title: String) {
        guard let idx = terminalTabs.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, terminalTabs[idx].title != trimmed else { return }
        terminalTabs[idx].title = trimmed
    }

    /// Update title/URL for a browser tab **without** changing `activeSurface`.
    func updateBrowserTab(id: UUID, title: String? = nil, urlString: String? = nil) {
        guard let idx = browserTabs.firstIndex(where: { $0.id == id }) else { return }
        if let title, browserTabs[idx].title != title {
            browserTabs[idx].title = title
        }
        if let urlString, browserTabs[idx].urlString != urlString {
            browserTabs[idx].urlString = urlString
        }
    }

    func browserTab(id: UUID) -> BrowserTab? {
        browserTabs.first { $0.id == id }
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

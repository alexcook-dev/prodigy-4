import AppKit
import SwiftData
import SwiftUI

/// Center pane: chat thread (default) or file preview tabs.
///
/// T5: wired to `ModelProvider` with streaming markdown + model/effort picker.
/// T13: category-specific error banner (one shape, dynamic text/CTA).
/// Wave 1 integration: file-tree selection flips this pane into preview;
/// ⌘2 always activates the Chat tab; ⌘⏎ from preview inserts a file reference.
struct CenterPaneView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var focus: WorkspaceFocusController
    @Bindable var selection: WorkspaceSelection
    @Bindable var chat: ChatController
    /// Browser / project root for relative paths in file preview chrome.
    var fileRootURL: URL? = nil
    var isFocused: Bool = true
    var onCreateProject: () -> Void
    var onQuickChat: () -> Void

    @Query(sort: \WorkspaceProject.lastActiveAt, order: .reverse)
    private var allProjects: [WorkspaceProject]

    @Query(sort: \Agent.name)
    private var agents: [Agent]

    @FocusState private var composerFocused: Bool
    @State private var scrollAnchor = UUID()
    @State private var showSettingsSheet = false
    @ObservedObject private var appleMail = AppleMailService.shared
    @ObservedObject private var appleCalendar = AppleCalendarService.shared
    @ObservedObject private var usageMeter = UsageMeterService.shared
    /// Persist reasoning visibility across launches.
    @AppStorage("prodigy.chat.showReasoning") private var showReasoningStored = true

    /// Explicit selection, or most-recent Project while launch resume applies
    /// (avoids a one-frame "Select a Project" flash — T14 skips any picker).
    private var selectedProject: WorkspaceProject? {
        if let id = selection.selectedProjectID,
           let match = allProjects.first(where: { $0.id == id }) {
            return match
        }
        guard !allProjects.isEmpty else { return nil }
        return allProjects.first(where: { !$0.archived }) ?? allProjects.first
    }

    private var selectedAgent: Agent? {
        guard let id = selection.selectedAgentID else { return nil }
        return agents.first { $0.id == id }
    }

    /// Active chat thread from the selected chat tab (multi-tab).
    private var activeThread: ChatThread? {
        guard let project = selectedProject else { return nil }
        if case .chat(let threadID) = selection.activeSurface {
            return project.threads.first { $0.id == threadID }
        }
        if let agent = selectedAgent {
            return project.thread(for: agent)
        }
        return project.primaryThread
    }

    /// Persona for the active thread (tab), not only the sidebar selection.
    private var activeThreadAgent: Agent? {
        activeThread?.agent ?? selectedAgent
    }

    private var isStreamingHere: Bool {
        guard let project = selectedProject, let thread = activeThread else { return false }
        return chat.isStreaming(projectID: project.id, threadID: thread.id)
    }

    private var errorHere: ProviderError? {
        guard let project = selectedProject, let thread = activeThread else { return nil }
        return chat.error(for: project.id, threadID: thread.id)
    }

    var body: some View {
        // Always keep terminal/browser views in the tree (even on Dashboard)
        // so switching Project/Workspace/chat never kills PTYs or WKWebViews.
        ZStack {
            persistentSurfacesLayer

            if selection.activeSurface == .dashboard {
                DashboardView(
                    selection: selection,
                    onCreateProject: onCreateProject
                )
                .zIndex(20)
            } else {
                // sc2 empty / sc4 active chat: tab bar + thread + composer.
                VStack(spacing: 0) {
                    tabBar

                    ephemeralLayer
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if case .chat = selection.activeSurface {
                        composerBar
                    }
                }
                .zIndex(5)
            }
        }
        // Fill the full middle column — only the 1pt split hairlines separate sides.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.centerBackground)
        // ⌘L focuses composer (sc4); ⌘⏎ discuss-in-chat stages a path ref.
        .onKeyPress(KeyEquivalent("l"), phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            openOrFocusChat()
            focus.activateChatTab()
            composerFocused = true
            return .handled
        }
        .onChange(of: selection.pendingComposerInsert) { _, value in
            guard let value else { return }
            chat.insertComposerText(value)
            selection.pendingComposerInsert = nil
            openOrFocusChat()
            focus.activateChatTab()
            composerFocused = true
        }
        .onChange(of: chat.composerFocusToken) { _, _ in
            composerFocused = true
        }
        // Opening a chat tab clears the green unread-activity dot for this Project.
        .onChange(of: selection.activeSurface) { _, surface in
            if case .chat = surface {
                selectedProject?.hasUnviewedActivity = false
                composerFocused = true
            }
        }
        // ⌘2 / Navigate → Chat: focus last chat tab or create/open one.
        .onChange(of: focus.chatTabActivationToken) { _, _ in
            openOrFocusChat()
            composerFocused = true
        }
        .onChange(of: isFocused) { _, focused in
            if focused, case .chat = selection.activeSurface {
                composerFocused = true
            }
        }
        .onAppear {
            chat.showReasoning = showReasoningStored
            if case .chat = selection.activeSurface {
                focus.focus(.chat)
                composerFocused = true
            }
            Task { await usageMeter.syncClaudeUsageFromCLI() }
        }
        .sheet(isPresented: $showSettingsSheet) {
            SettingsView()
        }
    }

    /// Focus an open chat tab, or open primary / create a new chat when none exist.
    private func openOrFocusChat() {
        if let project = selectedProject {
            _ = selection.showOrCreateChat(in: project, context: modelContext)
            return
        }
        // No project yet: create a quick-chat project with a primary thread.
        do {
            let created = try ProjectFactory.createQuickChat(in: modelContext)
            try modelContext.save()
            selection.selectProject(created)
            if let primary = created.primaryThread {
                selection.openChatTab(thread: primary)
            }
        } catch {
            onCreateProject()
        }
    }

    private func openNewChat() {
        if let project = selectedProject {
            _ = selection.openNewChatTab(in: project, context: modelContext)
            composerFocused = true
            return
        }
        openOrFocusChat()
    }

    // MARK: - Tabs

    private var tabBar: some View {
        HStack(spacing: 4) {
            // Multiple chat tabs — each maps to a ChatThread.
            ForEach(selection.chatTabs) { tab in
                CenterTab(
                    title: titleForChatTab(tab),
                    isActive: {
                        if case .chat(let openID) = selection.activeSurface {
                            return openID == tab.id
                        }
                        return false
                    }(),
                    showsClose: true,
                    onClose: { selection.closeChatTab(id: tab.id) }
                ) {
                    selection.selectChatTab(id: tab.id)
                    focus.focus(.chat)
                    composerFocused = true
                }
            }

            ForEach(selection.filePreviewTabs) { tab in
                CenterTab(
                    title: tab.fileName,
                    isActive: {
                        if case .filePreview(let open) = selection.activeSurface {
                            return open.id == tab.id
                        }
                        return false
                    }(),
                    showsClose: true,
                    onClose: { selection.closeFilePreview(id: tab.id) }
                ) {
                    selection.activeSurface = .filePreview(tab)
                }
            }

            if selection.isAppleMailTabOpen {
                CenterTab(
                    title: "Mail",
                    isActive: {
                        if case .appleMail = selection.activeSurface { return true }
                        return false
                    }(),
                    showsClose: true,
                    onClose: { selection.closeAppleMailTab() }
                ) {
                    selection.openAppleMailTab()
                }
            }

            if selection.isAppleCalendarTabOpen {
                CenterTab(
                    title: "Calendar",
                    isActive: {
                        if case .appleCalendar = selection.activeSurface { return true }
                        return false
                    }(),
                    showsClose: true,
                    onClose: { selection.closeAppleCalendarTab() }
                ) {
                    selection.openAppleCalendarTab()
                }
            }

            ForEach(selection.browserTabs) { tab in
                CenterTab(
                    title: tab.title,
                    isActive: {
                        if case .browser(let openID) = selection.activeSurface {
                            return openID == tab.id
                        }
                        return false
                    }(),
                    showsClose: true,
                    onClose: { selection.closeBrowserTab(id: tab.id) }
                ) {
                    selection.selectBrowserTab(tab)
                }
            }

            ForEach(selection.terminalTabs) { tab in
                CenterTab(
                    title: tab.title,
                    isActive: {
                        if case .terminal(let openID) = selection.activeSurface {
                            return openID == tab.id
                        }
                        return false
                    }(),
                    showsClose: true,
                    onClose: { selection.closeTerminalTab(id: tab.id) }
                ) {
                    selection.selectTerminalTab(tab)
                    focus.focus(.chat)
                }
            }

            // "+" : New Chat, file, Safari, Terminal, Apple Mail, Apple Calendar.
            Menu {
                Button("New Chat") {
                    openNewChat()
                    focus.focus(.chat)
                }
                if !selection.hasOpenChatTabs {
                    Button("Open Chat") {
                        openOrFocusChat()
                        focus.activateChatTab()
                        composerFocused = true
                    }
                }
                Button("Open File…") { openFilePreviewPicker() }
                Divider()
                Button {
                    selection.openSafariTab()
                } label: {
                    Label("Safari", systemImage: "safari")
                }
                Button {
                    openCenterTerminal()
                } label: {
                    Label("Terminal", systemImage: "terminal")
                }
                Button {
                    selection.openAppleMailTab()
                } label: {
                    Label("Mail", systemImage: "envelope.fill")
                }
                Button {
                    selection.openAppleCalendarTab()
                } label: {
                    Label("Calendar", systemImage: "calendar")
                }
            } label: {
                Image(systemName: "plus")
                    .font(Font.caption.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .menuStyle(.borderlessButton)
            .help("Open Chat, file, Safari, Terminal, Mail, or Calendar")

            Spacer()

            // Reasoning toggle — show model thinking/code before the reply.
            Toggle(isOn: Binding(
                get: { showReasoningStored },
                set: { newValue in
                    showReasoningStored = newValue
                    chat.showReasoning = newValue
                }
            )) {
                Image(systemName: "brain.head.profile")
                    .font(Font.caption)
            }
            .toggleStyle(.button)
            .help(showReasoningStored ? "Hide reasoning" : "Show reasoning")
            .foregroundStyle(showReasoningStored ? Theme.accent : Theme.textSecondary)

            // sc8 open-with dropdown (Finder, VS Code, Safari, Terminal, Mail, Calendar…).
            Menu {
                OpenWithMenuContent(
                    workspacePath: selection.workspacePath(from: Array(allProjects)),
                    onOpenSafari: { selection.openSafariTab() },
                    onOpenTerminal: { openCenterTerminal() },
                    onOpenMail: { selection.openAppleMailTab() },
                    onOpenCalendar: { selection.openAppleCalendarTab() }
                )
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(Font.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .menuStyle(.borderlessButton)
            .help("Open with…")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // Flush top bar — matches center well in both sc1 (dark) and sc2 (light).
        .background(Theme.centerBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.borderHairline)
                .frame(height: 1)
        }
    }

    private func titleForChatTab(_ tab: ChatTab) -> String {
        if let project = selectedProject,
           let thread = project.threads.first(where: { $0.id == tab.id }) {
            let t = thread.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
            if let name = thread.agent?.name, !name.isEmpty { return name }
        }
        return tab.title
    }

    /// Real file open for preview tabs (T11: never a second chat thread).
    private func openFilePreviewPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Preview"
        if let project = selectedProject {
            panel.directoryURL = URL(fileURLWithPath: project.folderPath, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selection.presentFilePreview(FilePreviewRequest(url: url))
    }

    // MARK: - Body

    /// Surfaces whose views stay mounted while other tabs / projects are active.
    private var isShowingPersistentSurface: Bool {
        switch selection.activeSurface {
        case .terminal, .browser: return true
        default: return false
        }
    }

    /// Mount **all** terminal/browser sessions (including those belonging to
    /// other Projects/Workspaces) so switching containers never kills a PTY.
    @ViewBuilder
    private var persistentSurfacesLayer: some View {
        ZStack {
            ForEach(selection.mountedTerminalTabs) { tab in
                let isActiveTerminal: Bool = {
                    if case .terminal(let openID) = selection.activeSurface {
                        return openID == tab.id
                    }
                    return false
                }()
                TerminalPaneView(
                    isFocused: isFocused && isActiveTerminal,
                    onPaneShortcut: { focus.focus($0) },
                    initialWorkingDirectory: tab.workingDirectory,
                    showsChromeHeader: false,
                    onTitleChange: { title in
                        selection.updateTerminalTab(id: tab.id, title: title)
                    }
                )
                .id(tab.id)
                .opacity(isActiveTerminal ? 1 : 0)
                .allowsHitTesting(isActiveTerminal)
                .accessibilityHidden(!isActiveTerminal)
                .zIndex(isActiveTerminal ? 10 : 0)
            }

            ForEach(selection.mountedBrowserTabs) { tab in
                let isActiveBrowser: Bool = {
                    if case .browser(let openID) = selection.activeSurface {
                        return openID == tab.id
                    }
                    return false
                }()
                SafariBrowserView(
                    tabID: tab.id,
                    initialURLString: tab.urlString,
                    defaultTitle: tab.title,
                    onClose: { selection.closeBrowserTab(id: tab.id) },
                    onUpdate: { title, url in
                        selection.updateBrowserTab(id: tab.id, title: title, urlString: url)
                    }
                )
                .id(tab.id)
                .opacity(isActiveBrowser ? 1 : 0)
                .allowsHitTesting(isActiveBrowser)
                .accessibilityHidden(!isActiveBrowser)
                .zIndex(isActiveBrowser ? 10 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Sit under dashboard / chat chrome; only the active terminal/browser
        // receives hits via allowsHitTesting above.
        .zIndex(isShowingPersistentSurface ? 15 : 0)
    }

    @ViewBuilder
    private var ephemeralLayer: some View {
        if isShowingPersistentSurface {
            // Active terminal/browser is drawn in `persistentSurfacesLayer`.
            Color.clear
        } else {
            ephemeralContentBody
        }
    }

    @ViewBuilder
    private var ephemeralContentBody: some View {
        switch selection.activeSurface {
        case .empty:
            emptyTabsBody
        case .chat(let threadID):
            chatBody
                .id(threadID) // Keep scroll/composer identity per thread tab.
        case .dashboard:
            EmptyView() // Hosted as full-pane body above.
        case .filePreview(let tab):
            filePreviewBody(tab)
        case .appleMail:
            AppleMailView(
                mail: appleMail,
                onClose: { selection.closeAppleMailTab() }
            )
        case .appleCalendar:
            AppleCalendarView(
                calendar: appleCalendar,
                onClose: { selection.closeAppleCalendarTab() }
            )
        case .browser, .terminal:
            // Hosted persistently in `persistentSurfacesLayer`.
            EmptyView()
        }
    }

    private func openCenterTerminal() {
        let cwd = selectedProject.map(\.folderPath)
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        _ = selection.openTerminalTab(workingDirectory: cwd)
        focus.focus(.chat)
    }

    /// Shown when every center tab was closed — invite re-open Chat, Safari, or Terminal.
    private var emptyTabsBody: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.on.square")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("No tabs open")
                .font(Font.title3.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
            Text("Open Chat, Safari, Terminal, Mail, or Calendar to continue.")
                .font(Font.subheadline)
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 12) {
                Button("New Chat") {
                    openNewChat()
                    focus.activateChatTab()
                    composerFocused = true
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("2", modifiers: .command)

                Button("Safari") {
                    selection.openSafariTab()
                }
                .buttonStyle(.bordered)

                Button("Terminal") {
                    openCenterTerminal()
                }
                .buttonStyle(.bordered)

                Button("Mail") {
                    selection.openAppleMailTab()
                }
                .buttonStyle(.bordered)

                Button("Calendar") {
                    selection.openAppleCalendarTab()
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.centerBackground)
    }

    /// Same structure whether empty or populated: scrollable thread + (via
    /// body) composer pinned below. Zero messages = blank scroll area only —
    /// no greeting, logo, CTA, or tip cards (PLAN.md IA / chat-panel norm).
    private var chatBody: some View {
        messageScroll(messages: activeThread?.sortedMessages ?? [])
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func messageScroll(messages: [Message]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(messages, id: \.id) { message in
                        messageBubble(message)
                            .id(message.id)
                    }

                    if isStreamingHere {
                        streamingBubble
                            .id("streaming")
                    }

                    if let error = errorHere {
                        ChatErrorBanner(
                            error: error,
                            detailsExpanded: chat.errorDetailsExpanded,
                            onCTA: { handleErrorCTA(error) },
                            onDismiss: { chat.dismissError() }
                        )
                        .id("error-banner")
                    }

                    Color.clear.frame(height: 1).id(scrollAnchor)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Continuous selection across the thread (copy by dragging).
                .textSelection(.enabled)
            }
            .onChange(of: messages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: chat.streamingText) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: chat.streamingReasoning) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: chat.streamPhase) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: errorHere?.category) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(scrollAnchor, anchor: .bottom)
        }
    }

    @ViewBuilder
    private func messageBubble(_ message: Message) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.content)
                    .font(Font.callout)
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 12,
                            bottomLeadingRadius: 12,
                            bottomTrailingRadius: 4,
                            topTrailingRadius: 12,
                            style: .continuous
                        )
                        .fill(Theme.userMessageFill)
                        .overlay(
                            UnevenRoundedRectangle(
                                topLeadingRadius: 12,
                                bottomLeadingRadius: 12,
                                bottomTrailingRadius: 4,
                                topTrailingRadius: 12,
                                style: .continuous
                            )
                            .strokeBorder(Theme.userMessageBorder, lineWidth: 1)
                        )
                    )
                    .frame(maxWidth: 480, alignment: .trailing)
            }
        case .assistant:
            // sc4: full-width markdown reply + reasoning + copy.
            VStack(alignment: .leading, spacing: 8) {
                if showReasoningStored,
                   let reasoning = message.reasoning,
                   !reasoning.isEmpty {
                    ReasoningDisclosure(text: reasoning)
                }

                StreamingMarkdownView(
                    text: message.content,
                    isStreaming: false,
                    isPartial: message.isPartial
                )

                HStack(spacing: 8) {
                    Text(relativeTime(message.createdAt))
                        .font(Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                    if let label = message.modelLabel, !label.isEmpty {
                        Text("·")
                            .foregroundStyle(Theme.textTertiary)
                        Text(label)
                            .font(Font.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 0)

                    Button {
                        copyToPasteboard(message.content)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(Font.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy response")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .system:
            Text(message.content)
                .font(Font.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = max(0, Int(-date.timeIntervalSinceNow))
        if seconds < 60 { return "\(max(seconds, 1))s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }

    @ViewBuilder
    private var streamingBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showReasoningStored, !chat.streamingReasoning.isEmpty {
                ReasoningDisclosure(text: chat.streamingReasoning, isLive: true)
            }

            if chat.streamPhase == .thinking && chat.streamingText.isEmpty {
                // wf-3 #1: pulsing dot + "Thinking…" + Stop
                HStack(spacing: 10) {
                    ThinkingPulse()
                    Text(chat.streamingReasoning.isEmpty ? "Thinking…" : "Writing…")
                        .font(Font.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    stopButton
                }
            } else {
                StreamingMarkdownView(
                    text: chat.streamingText,
                    isStreaming: true,
                    isPartial: false
                )
                HStack {
                    stopButton
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stopButton: some View {
        Button {
            if let id = selectedProject?.id {
                chat.stop(projectID: id)
            }
        } label: {
            Text("Stop")
                .font(Font.caption)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Theme.controlBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help("Stop generating")
        // Esc is reserved for file-preview close only (PLAN.md keyboard contract).
    }

    private func filePreviewBody(_ tab: FilePreviewTab) -> some View {
        let request = FilePreviewRequest(url: tab.url)
        return FilePreviewView(
            request: request,
            rootURL: fileRootURL,
            onClose: {
                selection.closeFilePreview(tab)
            },
            onDiscussInChat: {
                // ⌘⏎: go to chat + insert file reference into the composer
                // (PLAN.md Responsive & Accessibility / Next Step 4).
                selection.discussInChat(request)
                focus.activateChatTab()
            }
        )
    }

    // MARK: - Composer (sc2 idle / sc4 focused rainbow border)

    private var composerBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                TextField(composerPlaceholderText, text: $chat.composerText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Font.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2...10)
                    .focused($composerFocused)
                    .onSubmit {
                        // Return sends; shift-return is newline via TextField axis.
                        sendCurrentMessage()
                    }

                if chat.composerText.isEmpty && !composerFocused {
                    Text("⌘L to focus")
                        .font(Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 2)
                }
            }

            HStack(spacing: 8) {
                modelPicker
                effortPicker

                if chat.isBusy && isStreamingHere {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer(minLength: 8)

                // Live usage for the model currently selected in the picker.
                UsageGaugePill(model: chat.selectedModel, meter: usageMeter)

                Button {
                    sendCurrentMessage()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(Font.subheadline.weight(.bold))
                        .foregroundStyle(canSend ? Theme.textOnAccent : Theme.textTertiary)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(canSend ? Theme.accent : Theme.chipBackground)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (⌘⏎)")
            }
            .font(Font.caption)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.elevatedSurface)
        )
        .overlay {
            // sc4: rainbow focus ring when the field is active.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    composerFocused
                        ? AnyShapeStyle(composerRainbow)
                        : AnyShapeStyle(Theme.borderHairline),
                    lineWidth: composerFocused ? 1.5 : 1
                )
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .background(Theme.centerBackground)
        .onAppear {
            // Default caret to chat composer, not the terminal.
            chat.showReasoning = showReasoningStored
            composerFocused = true
            focus.focus(.chat)
        }
    }

    /// sc4 multi-stop accent gradient along the composer edge.
    private var composerRainbow: AngularGradient {
        AngularGradient(
            gradient: Gradient(colors: [
                Color(red: 1.0, green: 0.35, blue: 0.35),
                Color(red: 1.0, green: 0.75, blue: 0.2),
                Color(red: 0.35, green: 0.85, blue: 0.4),
                Color(red: 0.3, green: 0.7, blue: 1.0),
                Color(red: 0.7, green: 0.4, blue: 1.0),
                Color(red: 1.0, green: 0.35, blue: 0.35),
            ]),
            center: .center
        )
    }

    private var canSend: Bool {
        !chat.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !chat.isBusy
    }

    private var composerPlaceholderText: String {
        // sc2 / sc4 placeholder language.
        "Ask to make changes, @mention files, run /commands"
    }

    private var modelPicker: some View {
        Menu {
            Section("Claude") {
                ForEach(ChatModelOption.allCases.filter { $0.family == .claude }) { option in
                    Button {
                        chat.selectedModel = option
                    } label: {
                        if chat.selectedModel == option {
                            Label(option.displayName, systemImage: "checkmark")
                        } else {
                            Text(option.displayName)
                        }
                    }
                }
            }
            Section("Grok") {
                ForEach(ChatModelOption.allCases.filter { $0.family == .grok }) { option in
                    Button {
                        chat.selectedModel = option
                    } label: {
                        if chat.selectedModel == option {
                            Label(option.displayName, systemImage: "checkmark")
                        } else {
                            Text(option.displayName)
                        }
                    }
                }
            }
        } label: {
            composerPill(chat.selectedModel.pillLabel)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Model for the next turn (Claude or Grok)")
    }

    private var effortPicker: some View {
        Menu {
            ForEach(ChatEffortOption.allCases) { option in
                Button {
                    chat.selectedEffort = option
                } label: {
                    if chat.selectedEffort == option {
                        Label(option.displayName, systemImage: "checkmark")
                    } else {
                        Text(option.displayName)
                    }
                }
            }
        } label: {
            composerPill(chat.selectedEffort.pillLabel)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Effort for the next turn")
    }

    private func composerPill(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Theme.chipBackground)
            )
    }

    // MARK: - Actions

    private func sendCurrentMessage() {
        guard canSend else { return }
        // First message with no Project: auto-create a hidden quick-chat Project
        // so the center pane is never a creation gate (PLAN.md IA revision).
        let project: WorkspaceProject
        let thread: ChatThread
        if let existing = selectedProject, let existingThread = activeThread {
            project = existing
            thread = existingThread
        } else {
            do {
                let created = try ProjectFactory.createQuickChat(in: modelContext)
                try modelContext.save()
                selection.selectProject(created)
                guard let primary = created.primaryThread else { return }
                project = created
                thread = primary
            } catch {
                onCreateProject()
                return
            }
        }
        // Focused project → not background (T9 hasUnviewedActivity stays off).
        chat.send(
            project: project,
            thread: thread,
            agent: activeThreadAgent,
            context: modelContext,
            isBackground: false
        )
    }

    private func handleErrorCTA(_ error: ProviderError) {
        let action = chat.ctaAction(for: error)
        chat.performCTA(
            action,
            project: selectedProject,
            thread: activeThread,
            agent: activeThreadAgent,
            context: modelContext,
            focusTerminal: {
                focus.focus(.terminal)
            }
        )
    }
}

// MARK: - Thinking pulse (wf-3 #1)

private struct ThinkingPulse: View {
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(Theme.accent)
            .frame(width: 8, height: 8)
            .opacity(dimmed ? 0.3 : 1)
            .animation(
                .easeInOut(duration: 0.5).repeatForever(autoreverses: true),
                value: dimmed
            )
            .onAppear { dimmed = true }
            .accessibilityLabel("Thinking")
    }
}

// MARK: - Reasoning disclosure

private struct ReasoningDisclosure: View {
    let text: String
    var isLive: Bool = false
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(Font.caption2.weight(.semibold))
                    Image(systemName: "brain.head.profile")
                        .font(Font.caption)
                    Text(isLive ? "Reasoning…" : "Reasoning")
                        .font(Font.caption.weight(.medium))
                    if isLive {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text)
                    .font(Font.caption.monospaced())
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.chipBackground)
                    )
            }
        }
    }
}

// MARK: - Tab chrome

/// Tab chip with optional close control.
///
/// Close must be a **sibling** of the select control — never a Button nested
/// inside another Button (SwiftUI swallows the inner click on macOS).
private struct CenterTab: View {
    let title: String
    let isActive: Bool
    let showsClose: Bool
    var onClose: (() -> Void)? = nil
    let action: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button(action: action) {
                Text(title)
                    .font(isActive ? Font.subheadline.weight(.medium) : Font.subheadline)
                    .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .padding(.leading, 12)
                    .padding(.trailing, showsClose ? 4 : 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(title)

            if showsClose {
                Button {
                    onClose?()
                } label: {
                    Image(systemName: "xmark")
                        .font(Font.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Close tab")
                .padding(.trailing, 6)
            }
        }
        .glassEffect(
            isActive ? .regular.interactive() : .clear,
            in: Capsule(style: .continuous)
        )
    }
}

#Preview("With project") {
    let selection = WorkspaceSelection()
    let chat = ChatController()
    return CenterPaneView(
        selection: selection,
        chat: chat,
        onCreateProject: {},
        onQuickChat: {}
    )
    .environmentObject(WorkspaceFocusController())
    .frame(width: 640, height: 700)
    .preferredColorScheme(.dark)
    .modelContainer(for: [
        WorkspaceProject.self,
        Agent.self,
        ChatThread.self,
        Message.self,
    ], inMemory: true)
}

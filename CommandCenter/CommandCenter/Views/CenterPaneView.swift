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

    /// Active chat thread: agent-scoped if an Agent is selected, else primary.
    private var activeThread: ChatThread? {
        guard let project = selectedProject else { return nil }
        if let agent = selectedAgent {
            return project.thread(for: agent)
        }
        return project.primaryThread
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
        Group {
            if selection.activeSurface == .dashboard {
                DashboardView(
                    selection: selection,
                    onCreateProject: onCreateProject
                )
            } else {
                // sc2 empty / sc4 active chat: tab bar + thread + composer.
                VStack(spacing: 0) {
                    tabBar

                    contentBody
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if case .chat = selection.activeSurface {
                        composerBar
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.centerBackground)
        // Cap chat reading width on large displays; column still fills.
        .frame(maxWidth: LayoutMetrics.maxReadingWidth)
        .frame(maxWidth: .infinity)
        // ⌘L focuses composer (sc4); ⌘⏎ discuss-in-chat stages a path ref.
        .onKeyPress(KeyEquivalent("l"), phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            selection.showChat()
            focus.focus(.chat)
            composerFocused = true
            return .handled
        }
        .onChange(of: selection.pendingComposerInsert) { _, value in
            guard let value else { return }
            chat.insertComposerText(value)
            selection.pendingComposerInsert = nil
            selection.showChat()
            focus.focus(.chat)
            composerFocused = true
        }
        .onChange(of: chat.composerFocusToken) { _, _ in
            composerFocused = true
        }
        // Opening the chat tab clears the green unread-activity dot for this Project.
        .onChange(of: selection.activeSurface) { _, surface in
            if case .chat = surface {
                selectedProject?.hasUnviewedActivity = false
            }
        }
    }

    // MARK: - Tabs

    private var tabBar: some View {
        HStack(spacing: 4) {
            // Single chat tab per Project (V1) — never multi-thread from the tab bar.
            CenterTab(
                title: chatTabTitle,
                isActive: selection.activeSurface == .chat,
                showsClose: false
            ) {
                selection.showChat()
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
                    onClose: { selection.closeFilePreview(tab) }
                ) {
                    selection.activeSurface = .filePreview(tab)
                }
            }

            // T11: "+" opens file-preview tabs only, never a second chat thread.
            Button {
                openFilePreviewPicker()
            } label: {
                Image(systemName: "plus")
                    .font(Font.caption.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .help("Open file preview (never a second chat thread)")

            Spacer()
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

    private var chatTabTitle: String {
        if let agent = selectedAgent {
            return "Chat — \(agent.name)"
        }
        if let project = selectedProject {
            return "Chat — \(project.name)"
        }
        return "Chat"
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

    @ViewBuilder
    private var contentBody: some View {
        switch selection.activeSurface {
        case .chat:
            chatBody
        case .dashboard:
            EmptyView() // Hosted as full-pane body above.
        case .filePreview(let tab):
            filePreviewBody(tab)
        }
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
            }
            .onChange(of: messages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: chat.streamingText) { _, _ in
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
            // sc4: full-width markdown reply + compact meta footer.
            VStack(alignment: .leading, spacing: 8) {
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
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .system:
            Text(message.content)
                .font(Font.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
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
            if chat.streamPhase == .thinking && chat.streamingText.isEmpty {
                // wf-3 #1: pulsing dot + "Thinking…" + Stop
                HStack(spacing: 10) {
                    ThinkingPulse()
                    Text("Thinking…")
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
                focus.focus(.chat)
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
            if isFocused { composerFocused = true }
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
            ForEach(ChatModelOption.allCases) { option in
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
        } label: {
            composerPill(chat.selectedModel.pillLabel)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Model for the next turn")
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
            agent: selectedAgent,
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
            agent: selectedAgent,
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

// MARK: - Tab chrome

private struct CenterTab: View {
    let title: String
    let isActive: Bool
    let showsClose: Bool
    var onClose: (() -> Void)? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font((isActive ? Font.subheadline.weight(.medium) : Font.subheadline))
                    .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)

                if showsClose {
                    Button {
                        onClose?()
                    } label: {
                        Image(systemName: "xmark")
                            .font(Font.caption2.weight(.semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Close preview")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .glassEffect(
                isActive ? .regular.interactive() : .clear,
                in: Capsule(style: .continuous)
            )
        }
        .buttonStyle(.plain)
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

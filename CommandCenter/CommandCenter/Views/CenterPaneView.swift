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
        // Always show live chat chrome (tabs + body + composer). Never gate on
        // FirstRunView / "Good evening" — live feedback after Wave 0: center pane
        // defaults to an empty composer even with zero Projects (PLAN.md IA revision).
        VStack(spacing: 0) {
            tabBar
            contentBody
            if case .chat = selection.activeSurface {
                composerBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.centerBackground)
        // T16: cap chat reading width on large displays (~900–1000px).
        .frame(maxWidth: LayoutMetrics.maxReadingWidth)
        .frame(maxWidth: .infinity) // stay centered in the pane
        // No persistent full-pane focus ring — that reads as a permanent border.
        // Focus is shown on the composer text field instead (see composerBar).
        // ⌘⏎ discuss-in-chat: selection stages plain-text reference → composer.
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
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 7,
                            bottomLeadingRadius: 0,
                            bottomTrailingRadius: 0,
                            topTrailingRadius: 7,
                            style: .continuous
                        )
                        .fill(Theme.appBackground)
                    )
            }
            .buttonStyle(.plain)
            .help("Open file preview (never a second chat thread)")

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 0)
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
        case .filePreview(let tab):
            filePreviewBody(tab)
        }
    }

    private var chatBody: some View {
        Group {
            // Always empty-chat or message list — never a gated greeting/CTA.
            if let thread = activeThread {
                let messages = thread.sortedMessages
                if messages.isEmpty && !isStreamingHere && errorHere == nil {
                    emptyThreadState
                } else {
                    messageScroll(messages: messages)
                }
            } else {
                emptyThreadState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyThreadState: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let project = selectedProject {
                Text(project.folderPath)
                    .font(.system(size: 12).monospaced())
                    .foregroundStyle(Theme.textSecondary)
            }

            Text(
                selectedAgent == nil
                    ? "No messages yet. Ask anything about this project."
                    : "New conversation with \(selectedAgent!.name)\(selectedProject.map { " in \($0.name)" } ?? "")."
            )
            .font(.system(size: 13))
            .foregroundStyle(Theme.textPrimary)

            // D4: only generic chips — no folder-aware chips (those need tools).
            HStack(spacing: 8) {
                suggestionChip("Plan today")
                suggestionChip("Something else")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func suggestionChip(_ title: String) -> some View {
        Button {
            chat.applySuggestion(title)
            sendCurrentMessage()
        } label: {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Theme.chipBackground)
                        .overlay(
                            Capsule()
                                .strokeBorder(Theme.borderStructural, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(chat.isBusy)
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
                    .font(.system(size: 13))
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
            VStack(alignment: .leading, spacing: 4) {
                Text(message.modelLabel ?? "Assistant")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)

                StreamingMarkdownView(
                    text: message.content,
                    isStreaming: false,
                    isPartial: message.isPartial
                )
            }
        case .system:
            Text(message.content)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder
    private var streamingBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(chat.streamingModelLabel ?? chat.selectedModel.messageLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)

            if chat.streamPhase == .thinking && chat.streamingText.isEmpty {
                // wf-3 #1: pulsing dot + "Thinking…" + Stop
                HStack(spacing: 10) {
                    ThinkingPulse()
                    Text("Thinking…")
                        .font(.system(size: 12))
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
    }

    private var stopButton: some View {
        Button {
            if let id = selectedProject?.id {
                chat.stop(projectID: id)
            }
        } label: {
            Text("Stop")
                .font(.system(size: 11))
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

    // MARK: - Composer (T5 — no usage meter in V1)

    private var composerBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(composerPlaceholderText, text: $chat.composerText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1...8)
                    .focused($composerFocused)
                    .onSubmit {
                        // Return sends; shift-return is newline via TextField axis.
                        sendCurrentMessage()
                    }

                if chat.isBusy && isStreamingHere {
                    // Busy indicator on the right of the field while streaming.
                    ProgressView()
                        .controlSize(.small)
                        .padding(.bottom, 2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.elevatedSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            // Focus ring on the composer control only (not the whole pane).
                            .strokeBorder(
                                composerFocused ? Theme.focusRing : Theme.borderStructural,
                                lineWidth: composerFocused ? 2 : 1
                            )
                    )
            )
            .overlay(alignment: .trailing) {
                if chat.composerText.isEmpty {
                    Text("⏎ send · ⇧⏎ newline")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.trailing, 12)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 8) {
                modelPicker
                effortPicker
                Spacer()
                // Usage meter intentionally omitted in V1 (PLAN.md NOT in Scope / Pass 7 #18).
                Button {
                    sendCurrentMessage()
                } label: {
                    Text("Send")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(
                            canSend ? Theme.accentText : Theme.textTertiary
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .font(.system(size: 11))
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.borderHairline)
                .frame(height: 1)
        }
        .onAppear {
            if isFocused { composerFocused = true }
        }
    }

    private var canSend: Bool {
        !chat.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !chat.isBusy
    }

    private var composerPlaceholderText: String {
        if let agent = selectedAgent {
            return "Message \(agent.name)…"
        }
        if let project = selectedProject {
            return "Message \(project.name)…"
        }
        return "Message…"
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
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Theme.chipBackground)
                    .overlay(
                        Capsule()
                            .strokeBorder(Theme.borderStructural, lineWidth: 1)
                    )
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
                    .font(.system(size: 12, weight: isActive ? .medium : .regular))
                    .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)

                if showsClose {
                    Button {
                        onClose?()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Close preview")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: 7,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 7,
                    style: .continuous
                )
                .fill(isActive ? Theme.centerBackground : Theme.appBackground)
                .overlay(alignment: .bottom) {
                    if isActive {
                        Rectangle()
                            .fill(Theme.centerBackground)
                            .frame(height: 2)
                            .offset(y: 1)
                    }
                }
                .overlay {
                    if isActive {
                        UnevenRoundedRectangle(
                            topLeadingRadius: 7,
                            bottomLeadingRadius: 0,
                            bottomTrailingRadius: 0,
                            topTrailingRadius: 7,
                            style: .continuous
                        )
                        .strokeBorder(Theme.borderHairline, lineWidth: 1)
                    }
                }
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

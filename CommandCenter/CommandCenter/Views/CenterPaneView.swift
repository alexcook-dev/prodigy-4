import SwiftData
import SwiftUI

/// Center pane: chat thread (default) or file preview tabs.
/// Chat streaming / provider wiring land later; this wave wires selection,
/// first-run, single-thread V1, and file-preview tabs only (T11).
struct CenterPaneView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var selection: WorkspaceSelection
    /// Browser / project root for relative paths in file preview chrome.
    var fileRootURL: URL? = nil
    var isFocused: Bool = true
    var onCreateProject: () -> Void
    var onQuickChat: () -> Void

    @Query(sort: \WorkspaceProject.lastActiveAt, order: .reverse)
    private var allProjects: [WorkspaceProject]

    @Query(sort: \Agent.name)
    private var agents: [Agent]

    private var selectedProject: WorkspaceProject? {
        guard let id = selection.selectedProjectID else { return nil }
        return allProjects.first { $0.id == id }
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

    /// True first-run: zero Projects ever (including hidden quick-chat).
    private var isFirstRun: Bool {
        allProjects.isEmpty
    }

    var body: some View {
        Group {
            if isFirstRun {
                FirstRunView(
                    onCreateProject: onCreateProject,
                    onQuickChat: onQuickChat
                )
            } else {
                VStack(spacing: 0) {
                    tabBar
                    contentBody
                    if case .chat = selection.activeSurface {
                        composerPlaceholder
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.centerBackground)
        // T16: cap chat reading width on large displays (~900–1000px).
        .frame(maxWidth: LayoutMetrics.maxReadingWidth)
        .frame(maxWidth: .infinity) // stay centered in the pane
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(Theme.focusRing, lineWidth: 2)
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
                openDemoFilePreview()
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

    /// Stub until T6 wires real file selection → preview. Proves the tab bar
    /// "+" only ever opens file-preview surfaces, never a second thread.
    private func openDemoFilePreview() {
        let project = selectedProject
        let base = project?.folderPath ?? ProjectFactory.defaultProjectsRoot.path
        let name = "preview-\(selection.filePreviewTabs.count + 1).txt"
        selection.openFilePreview(
            fileName: name,
            filePath: (base as NSString).appendingPathComponent(name)
        )
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
            if selectedProject == nil {
                noProjectSelected
            } else if let thread = activeThread, !thread.sortedMessages.isEmpty {
                messageList(thread.sortedMessages)
            } else {
                emptyThreadState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noProjectSelected: some View {
        VStack(spacing: 10) {
            Text("Select a Project")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
            Text("Choose one from the sidebar, or create a new Project to start chatting.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button(action: onCreateProject) {
                Text("New Project")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.accentText)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyThreadState: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let project = selectedProject {
                Text(project.folderPath)
                    .font(.system(size: 12).monospaced())
                    .foregroundStyle(Theme.textSecondary)

                Text(
                    selectedAgent == nil
                        ? "No messages yet. Ask anything about this project."
                        : "New conversation with \(selectedAgent!.name) in \(project.name)."
                )
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)

                HStack(spacing: 8) {
                    suggestionChip("Plan today")
                    suggestionChip("Something else")
                }
            }

            Text("Chat UI is a placeholder — provider + streaming land in later waves.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 8)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func suggestionChip(_ title: String) -> some View {
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

    private func messageList(_ messages: [Message]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(messages, id: \.id) { message in
                    messageBubble(message)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
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

                Text(
                    message.isPartial
                        ? message.content + "\n\n[partial — kept]"
                        : message.content
                )
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(3)
                .frame(maxWidth: 720, alignment: .leading)
            }
        case .system:
            Text(message.content)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func filePreviewBody(_ tab: FilePreviewTab) -> some View {
        let request = FilePreviewRequest(url: tab.url)
        return FilePreviewView(
            request: request,
            rootURL: fileRootURL,
            onClose: { selection.closeFilePreview(tab) },
            onDiscussInChat: { selection.discussInChat(request) }
        )
    }

    // MARK: - Composer (placeholder; no usage meter in V1)

    private var composerPlaceholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(composerPlaceholderText)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("⏎ send · ⇧⏎ newline")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.elevatedSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Theme.borderStructural, lineWidth: 1)
                    )
            )

            HStack(spacing: 8) {
                composerPill("Claude · Sonnet")
                composerPill("Effort: High")
                Spacer()
                // Usage meter intentionally omitted in V1 (PLAN.md NOT in Scope / Pass 7 #18).
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
    return CenterPaneView(
        selection: selection,
        onCreateProject: {},
        onQuickChat: {}
    )
    .frame(width: 640, height: 700)
    .preferredColorScheme(.dark)
    .modelContainer(for: [
        WorkspaceProject.self,
        Agent.self,
        ChatThread.self,
        Message.self,
    ], inMemory: true)
}

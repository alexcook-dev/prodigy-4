import SwiftData
import SwiftUI

/// Root 4-pane shell: sidebar | center chat/preview | right files/terminal.
///
/// Wave 1 combined: SwiftData (data), lazy files, SwiftTerm, and T16 window
/// behavior (persisted NSSplitView dividers + narrow right-column drawer).
struct WorkspaceRootView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var focus: WorkspaceFocusController

    @State private var selection = WorkspaceSelection()
    @State private var chat = ChatController()
    @State private var showProjectSheet = false
    @StateObject private var fileBrowser = FileBrowserModel()

    /// Overlay drawer for Files/Terminal when the window is below the collapse breakpoint.
    @State private var isRightColumnDrawerPresented = false
    /// Live window content width — drives the narrow-width collapse.
    @State private var windowWidth: CGFloat = LayoutMetrics.defaultWindowWidth

    @Query(sort: \WorkspaceProject.lastActiveAt, order: .reverse)
    private var allProjects: [WorkspaceProject]

    private var isNarrow: Bool {
        windowWidth < LayoutMetrics.rightColumnCollapseBreakpoint
    }

    var body: some View {
        // GlassEffectContainer lets neighboring glass shapes share a coherent
        // sampling layer (WWDC25 Liquid Glass composition).
        GlassEffectContainer(spacing: LiquidGlassMetrics.interPaneGap) {
            ZStack(alignment: .trailing) {
                mainSplit
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(LiquidGlassMetrics.windowInset)

                if isNarrow && isRightColumnDrawerPresented {
                    rightColumnDrawer
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background(Color.clear)
        .background(
            GeometryReader { geo in
                Color.clear
                    .preference(key: WindowWidthPreferenceKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(WindowWidthPreferenceKey.self) { width in
            windowWidth = width
        }
        .onChange(of: isNarrow) { _, narrow in
            if !narrow { isRightColumnDrawerPresented = false }
        }
        .animation(.easeInOut(duration: 0.18), value: isRightColumnDrawerPresented)
        .preferredColorScheme(nil)
        .toolbar {
            if isNarrow {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isRightColumnDrawerPresented.toggle()
                    } label: {
                        Label(
                            isRightColumnDrawerPresented
                                ? "Hide Files & Terminal"
                                : "Show Files & Terminal",
                            systemImage: isRightColumnDrawerPresented
                                ? "sidebar.trailing"
                                : "rectangle.righthalf.inset.filled"
                        )
                    }
                    .help("Toggle Files & Terminal panel")
                }
            }
        }
        .focusable()
        .onKeyPress(keys: [.init("1"), .init("2"), .init("3"), .init("4")]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            switch press.key {
            case "1": focus.focus(.sidebar)
            case "2":
                focus.focus(.chat)
                selection.showChat()
            case "3":
                focus.focus(.files)
                openRightColumnIfCollapsed()
            case "4":
                focus.focus(.terminal)
                openRightColumnIfCollapsed()
            default: return .ignored
            }
            return .handled
        }
        .sheet(isPresented: $showProjectSheet) {
            ProjectCreationSheet { project in
                selection.selectProject(project)
            }
        }
        .onAppear {
            performLaunchResumeIfNeeded()
            rebindFileRoot()
            // T9: keep the LRU pool's "focused" slot aligned with the sidebar.
            ClaudeCLIProvider.shared.setFocusedProject(selection.selectedProjectID)
            chat.focusedProjectID = selection.selectedProjectID
        }
        .onChange(of: allProjects.count) { _, _ in
            performLaunchResumeIfNeeded()
        }
        .onChange(of: selection.selectedProjectID) { _, newID in
            rebindFileRoot()
            ClaudeCLIProvider.shared.setFocusedProject(newID)
            chat.focusedProjectID = newID
        }
        // ⌘2 / Navigate → Chat: always flip the center surface to the Chat tab
        // (PLAN.md Responsive & Accessibility). Works even when the AppKit
        // TerminalView is first responder (menu key-equivalent path).
        .onChange(of: focus.chatTabActivationToken) { _, _ in
            selection.showChat()
        }
        // T9: background reply finished → green unread-activity status-dot.
        .onReceive(
            NotificationCenter.default.publisher(for: .claudeCLIBackgroundReplyCompleted)
        ) { note in
            guard let projectID = note.userInfo?["projectID"] as? UUID else { return }
            // Focused Project already clears the flag on selection; only light
            // the dot for Projects the user isn't currently viewing.
            if selection.selectedProjectID == projectID { return }
            if let project = allProjects.first(where: { $0.id == projectID }) {
                project.hasUnviewedActivity = true
            }
        }
    }

    // MARK: - Main split

    private var mainSplit: some View {
        Group {
            if isNarrow {
                PersistableHSplitView(
                    autosaveName: "CommandCenter.MainSplit.Narrow",
                    panes: [
                        .init(
                            minWidth: LayoutMetrics.sidebarMinWidth,
                            idealWidth: LayoutMetrics.sidebarWidth,
                            maxWidth: LayoutMetrics.sidebarMaxWidth,
                            holdingPriority: .defaultHigh
                        ) {
                            sidebarPane
                        },
                        .init(
                            minWidth: LayoutMetrics.centerMinWidth,
                            holdingPriority: .defaultLow
                        ) {
                            centerPane
                        },
                    ]
                )
            } else {
                PersistableHSplitView(
                    autosaveName: "CommandCenter.MainSplit.Wide",
                    panes: [
                        .init(
                            minWidth: LayoutMetrics.sidebarMinWidth,
                            idealWidth: LayoutMetrics.sidebarWidth,
                            maxWidth: LayoutMetrics.sidebarMaxWidth,
                            holdingPriority: .defaultHigh
                        ) {
                            sidebarPane
                        },
                        .init(
                            minWidth: LayoutMetrics.centerMinWidth,
                            holdingPriority: .defaultLow
                        ) {
                            centerPane
                        },
                        .init(
                            minWidth: LayoutMetrics.rightColumnMinWidth,
                            idealWidth: LayoutMetrics.rightColumnWidth,
                            maxWidth: LayoutMetrics.rightColumnMaxWidth,
                            holdingPriority: .defaultHigh
                        ) {
                            rightColumn
                        },
                    ]
                )
            }
        }
    }

    private var sidebarPane: some View {
        // No outer glass slab — Projects and Agents are separate nested cards
        // (same pattern as Files / Terminal on the right).
        SidebarView(
            selection: selection,
            chat: chat,
            isFocused: focus.focusedPane == .sidebar
        )
        .contentShape(Rectangle())
        .onTapGesture { focus.focus(.sidebar) }
        .padding(LiquidGlassMetrics.slotInset)
    }

    private var centerPane: some View {
        // Center is a lighter shell: glass frame with clear reading well so
        // the message stream stays sharp (Apple guidance: glass = chrome).
        CenterPaneView(
            selection: selection,
            chat: chat,
            fileRootURL: fileBrowser.rootURL,
            isFocused: focus.focusedPane == .chat,
            onCreateProject: { showProjectSheet = true },
            onQuickChat: startQuickChat
        )
        .contentShape(Rectangle())
        .onTapGesture { focus.focus(.chat) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .liquidGlassCard(cornerRadius: LiquidGlassMetrics.paneCorner)
        .padding(LiquidGlassMetrics.slotInset)
    }

    private var rightColumn: some View {
        RightColumnView(
            fileBrowser: fileBrowser,
            previewPresenter: selection,
            project: currentProject,
            filesFocused: focus.focusedPane == .files,
            terminalFocused: focus.focusedPane == .terminal,
            onFocusFiles: { focus.focus(.files) },
            onFocusTerminal: { focus.focus(.terminal) },
            onPaneShortcut: { focus.focus($0) }
        )
        .padding(LiquidGlassMetrics.slotInset)
    }

    private var rightColumnDrawer: some View {
        HStack(spacing: 0) {
            Color.black.opacity(0.18)
                .contentShape(Rectangle())
                .onTapGesture { isRightColumnDrawerPresented = false }

            rightColumn
                .frame(width: LayoutMetrics.rightColumnDrawerWidth)
                .padding(.vertical, LiquidGlassMetrics.windowInset)
                .padding(.trailing, LiquidGlassMetrics.windowInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openRightColumnIfCollapsed() {
        if isNarrow {
            isRightColumnDrawerPresented = true
        }
    }

    // MARK: - Data

    private var currentProject: WorkspaceProject? {
        guard let id = selection.selectedProjectID else { return nil }
        return allProjects.first { $0.id == id }
    }

    /// T14 / D6: auto-select last-active Project/thread; true first-run leaves
    /// selection empty so FirstRunView (wf-2) is shown — never a picker.
    private func performLaunchResumeIfNeeded() {
        guard !allProjects.isEmpty else {
            ClaudeCLIProvider.shared.setFocusedProject(nil)
            return
        }

        if selection.didPerformLaunchResume,
           let id = selection.selectedProjectID,
           allProjects.contains(where: { $0.id == id }) {
            ClaudeCLIProvider.shared.setFocusedProject(id)
            return
        }

        if let id = selection.selectedProjectID,
           let project = allProjects.first(where: { $0.id == id }) {
            let thread = WorkspaceSelection.mostRecentThread(in: project)
            if let thread, let agent = thread.agent, selection.selectedAgentID == nil {
                selection.selectedAgentID = agent.id
            }
            selection.prepareSessionResume(project: project, thread: thread)
            selection.markLaunchResumeComplete()
            selection.showChat()
            focus.focus(.chat)
            return
        }

        if let restored = selection.resumeLastActive(from: allProjects) {
            try? modelContext.save()
            selection.prepareSessionResume(
                project: restored.project,
                thread: restored.thread
            )
            focus.focus(.chat)
        }
    }

    private func rebindFileRoot() {
        if let path = currentProject?.folderPath {
            fileBrowser.setRoot(URL(fileURLWithPath: path, isDirectory: true))
        } else {
            // No Project selected: still show a real tree rooted at ~ (PLAN.md
            // IA revision after Wave 0). Project selection rebinds to its folder.
            fileBrowser.setRoot(FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    private func startQuickChat() {
        do {
            let project = try ProjectFactory.createQuickChat(in: modelContext)
            try modelContext.save()
            selection.selectProject(project)
            focus.focus(.chat)
            selection.showChat()
        } catch {
            showProjectSheet = true
        }
    }
}

enum WorkspacePane: Hashable, CaseIterable {
    case sidebar
    case chat
    case files
    case terminal

    var menuTitle: String {
        switch self {
        case .sidebar: return "Sidebar"
        case .chat: return "Chat"
        case .files: return "Files"
        case .terminal: return "Terminal"
        }
    }

    var shortcutDigit: Character {
        switch self {
        case .sidebar: return "1"
        case .chat: return "2"
        case .files: return "3"
        case .terminal: return "4"
        }
    }
}

// MARK: - Right column

private struct RightColumnView: View {
    @ObservedObject var fileBrowser: FileBrowserModel
    var previewPresenter: FilePreviewPresenting
    let project: WorkspaceProject?
    let filesFocused: Bool
    let terminalFocused: Bool
    let onFocusFiles: () -> Void
    let onFocusTerminal: () -> Void
    let onPaneShortcut: (WorkspacePane) -> Void

    var body: some View {
        // Two stacked glass cards (not one opaque VSplitView slab).
        VStack(spacing: LiquidGlassMetrics.interPaneGap) {
            FileBrowserPaneView(
                model: fileBrowser,
                previewPresenter: previewPresenter,
                isFocused: filesFocused
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: onFocusFiles)
            .liquidGlassNested()

            TerminalPaneView(
                isFocused: terminalFocused,
                onPaneShortcut: onPaneShortcut
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: onFocusTerminal)
            .liquidGlassNested()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }
}

// MARK: - Window width preference

private struct WindowWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = LayoutMetrics.defaultWindowWidth
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#Preview("Workspace shell") {
    WorkspaceRootView()
        .environmentObject(WorkspaceFocusController())
        .frame(width: 1200, height: 760)
        .modelContainer(for: [
            WorkspaceProject.self,
            Agent.self,
            ChatThread.self,
            Message.self,
        ], inMemory: true)
}

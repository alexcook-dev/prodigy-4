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
        ZStack(alignment: .trailing) {
            mainSplit
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if isNarrow && isRightColumnDrawerPresented {
                rightColumnDrawer
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(Theme.appBackground)
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
            // T14: auto-select last-active Project + resume its thread (D5.3);
            // true first-run (zero Projects) leaves selection empty → wf-2.
            performLaunchResumeIfNeeded()
            rebindFileRoot()
        }
        .onChange(of: allProjects.count) { _, _ in
            // Projects may appear after SwiftData finishes loading, or after
            // the first Project is created from the greeting screen.
            performLaunchResumeIfNeeded()
        }
        .onChange(of: selection.selectedProjectID) { _, newID in
            rebindFileRoot()
            ClaudeCLIProvider.shared.setFocusedProject(newID)
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
        SidebarView(
            selection: selection,
            isFocused: focus.focusedPane == .sidebar
        )
        .contentShape(Rectangle())
        .onTapGesture { focus.focus(.sidebar) }
    }

    private var centerPane: some View {
        CenterPaneView(
            selection: selection,
            fileRootURL: fileBrowser.rootURL,
            isFocused: focus.focusedPane == .chat,
            onCreateProject: { showProjectSheet = true },
            onQuickChat: startQuickChat
        )
        .contentShape(Rectangle())
        .onTapGesture { focus.focus(.chat) }
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
    }

    private var rightColumnDrawer: some View {
        HStack(spacing: 0) {
            Color.black.opacity(0.18)
                .contentShape(Rectangle())
                .onTapGesture { isRightColumnDrawerPresented = false }

            rightColumn
                .frame(width: LayoutMetrics.rightColumnDrawerWidth)
                .background(Theme.appBackground)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Theme.borderStructural)
                        .frame(width: 1)
                }
                .shadow(color: .black.opacity(0.25), radius: 12, x: -4, y: 0)
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

    /// T14 / D6 launch behavior.
    ///
    /// - Zero Projects ever → leave selection nil; `CenterPaneView` shows
    ///   `FirstRunView` (wf-2). No picker, no auto-create.
    /// - Any Project exists → select the most-recently-active by `lastActiveAt`
    ///   (updated on every selection) and open its most recent thread. Warm
    ///   the Claude CLI via `--resume` / D5.3 rehydrate path so the next turn
    ///   continues mid-conversation without a cold start.
    private func performLaunchResumeIfNeeded() {
        // True first-run: zero Projects — greeting screen only.
        guard !allProjects.isEmpty else {
            ClaudeCLIProvider.shared.setFocusedProject(nil)
            return
        }

        // Already restored this session and selection still points at a live Project.
        if selection.didPerformLaunchResume,
           let id = selection.selectedProjectID,
           allProjects.contains(where: { $0.id == id }) {
            ClaudeCLIProvider.shared.setFocusedProject(id)
            return
        }

        // Selection already set this session (e.g. ProjectCreationSheet just
        // called selectProject) but launch resume hasn't warmed the CLI yet.
        if let id = selection.selectedProjectID,
           let project = allProjects.first(where: { $0.id == id }) {
            let thread = WorkspaceSelection.mostRecentThread(in: project)
            // If an Agent thread is more recent, restore that persona too.
            if let thread, let agent = thread.agent, selection.selectedAgentID == nil {
                selection.selectedAgentID = agent.id
            }
            selection.prepareSessionResume(project: project, thread: thread)
            selection.markLaunchResumeComplete()
            selection.showChat()
            focus.focus(.chat)
            return
        }

        // Cold launch with existing Projects: auto-select last-active, no picker.
        // `allProjects` is sorted by lastActiveAt descending.
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
            fileBrowser.setRoot(nil)
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
        VSplitView {
            FileBrowserPaneView(
                model: fileBrowser,
                previewPresenter: previewPresenter,
                isFocused: filesFocused
            )
            .frame(minHeight: 120)
            .contentShape(Rectangle())
            .onTapGesture(perform: onFocusFiles)

            TerminalPaneView(
                isFocused: terminalFocused,
                onPaneShortcut: onPaneShortcut
            )
            .frame(minHeight: 100)
            .contentShape(Rectangle())
            .onTapGesture(perform: onFocusTerminal)
        }
        .background(Theme.appBackground)
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

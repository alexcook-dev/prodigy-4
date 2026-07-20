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
    @ObservedObject private var appUpdates = AppUpdateService.shared

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
        // sc1 shell: flush edge-to-edge columns, no outer window padding.
        ZStack(alignment: .trailing) {
            mainSplit
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if isNarrow && isRightColumnDrawerPresented {
                rightColumnDrawer
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            // Bottom-left update toast (does not steal layout from columns).
            VStack {
                Spacer(minLength: 0)
                HStack {
                    AppUpdateToast(updates: appUpdates)
                    Spacer(minLength: 0)
                }
            }
            .allowsHitTesting(appUpdates.shouldShowBanner)
        }
        .background(Theme.appBackground)
        .task {
            // Quiet production-only check a moment after launch.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await appUpdates.checkOnLaunchIfNeeded()
        }
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
        .focusEffectDisabled()
        .onKeyPress(keys: [.init("1"), .init("2"), .init("3"), .init("4")]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            switch press.key {
            case "1": focus.focus(.sidebar)
            case "2":
                // Explicit Chat-tab activation (not mere center-pane focus).
                focus.activateChatTab()
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
            // Files always defaults to the logged-in user's home — not the project folder.
            ensureFilesAtUserHome()
            // T9: keep the LRU pool's "focused" slot aligned with the sidebar.
            RoutingModelProvider.shared.setFocusedProject(selection.selectedProjectID)
            chat.focusedProjectID = selection.selectedProjectID
        }
        .onChange(of: allProjects.count) { _, _ in
            performLaunchResumeIfNeeded()
        }
        .onChange(of: selection.selectedProjectID) { _, newID in
            // Do NOT rebind Files to the project path — home stays the default.
            // User can open the project folder from the Files location menu.
            RoutingModelProvider.shared.setFocusedProject(newID)
            chat.focusedProjectID = newID
        }
        // Only `activateChatTab()` bumps this token (⌘2 / Navigate → Chat).
        // Plain center-pane focus must NOT call showChat — that was ejecting
        // the Safari tab when the user clicked Google result links.
        // CenterPaneView also observes this token and creates a chat if needed.
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
        // ⌘W / Navigate → Close Tab
        .onReceive(NotificationCenter.default.publisher(for: .prodigyCloseActiveTab)) { _ in
            _ = selection.closeActiveTab()
        }
    }

    // MARK: - Main split

    private var mainSplit: some View {
        Group {
            if isNarrow {
                // 25% sidebar / 75% center when the right column is collapsed.
                PersistableHSplitView(
                    // v5: 15% | 85% narrow layout.
                    autosaveName: "CommandCenter.MainSplit.Narrow.v5-15-85",
                    panes: [
                        .init(
                            minWidth: LayoutMetrics.sidebarMinWidth,
                            idealFraction: LayoutMetrics.sidebarNarrowDefaultFraction,
                            maxWidth: LayoutMetrics.sidebarMaxWidth,
                            maxFraction: LayoutMetrics.sidePaneMaxFraction,
                            holdingPriority: .defaultHigh
                        ) {
                            sidebarPane
                        },
                        .init(
                            minWidth: LayoutMetrics.centerMinWidth,
                            idealFraction: LayoutMetrics.centerNarrowDefaultFraction,
                            holdingPriority: .defaultLow
                        ) {
                            centerPane
                        },
                    ]
                )
            } else {
                // Display-relative defaults: 15% | 70% | 15% with 1pt hairline dividers.
                PersistableHSplitView(
                    // v5: 15% | 70% | 15% (bumped so old 25/50/25 prefs don't stick).
                    autosaveName: "CommandCenter.MainSplit.Wide.v5-15-70-15",
                    panes: [
                        .init(
                            minWidth: LayoutMetrics.sidebarMinWidth,
                            idealFraction: LayoutMetrics.sidebarDefaultFraction,
                            maxWidth: LayoutMetrics.sidebarMaxWidth,
                            maxFraction: LayoutMetrics.sidePaneMaxFraction,
                            holdingPriority: .defaultHigh
                        ) {
                            sidebarPane
                        },
                        .init(
                            minWidth: LayoutMetrics.centerMinWidth,
                            idealFraction: LayoutMetrics.centerDefaultFraction,
                            holdingPriority: .defaultLow
                        ) {
                            centerPane
                        },
                        .init(
                            minWidth: LayoutMetrics.rightColumnMinWidth,
                            idealFraction: LayoutMetrics.rightColumnDefaultFraction,
                            maxWidth: LayoutMetrics.rightColumnMaxWidth,
                            maxFraction: LayoutMetrics.sidePaneMaxFraction,
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
            chat: chat,
            isFocused: focus.focusedPane == .sidebar
        )
        .contentShape(Rectangle())
        .onTapGesture { focus.focus(.sidebar) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.sidebarBackground)
    }

    private var centerPane: some View {
        CenterPaneView(
            selection: selection,
            chat: chat,
            fileRootURL: fileBrowser.rootURL,
            isFocused: focus.focusedPane == .chat,
            onCreateProject: { showProjectSheet = true },
            onQuickChat: startQuickChat
        )
        // Focus the center *pane* only — never force the Chat *tab*.
        // Safari/file-preview clicks must stay on their surface.
        .contentShape(Rectangle())
        .onTapGesture { focus.focus(.chat) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.centerBackground)
    }

    private var rightColumn: some View {
        RightColumnView(
            fileBrowser: fileBrowser,
            previewPresenter: selection,
            project: currentProject,
            projectFolderURL: activeProjectFolderURL,
            filesFocused: focus.focusedPane == .files,
            terminalFocused: focus.focusedPane == .terminal,
            onFocusFiles: { focus.focus(.files) },
            onFocusTerminal: { focus.focus(.terminal) },
            onPaneShortcut: { focus.focus($0) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // sc1/sc2: right column matches center (not sidebar gray).
        .background(Theme.centerBackground)
    }

    private var rightColumnDrawer: some View {
        HStack(spacing: 0) {
            Color.black.opacity(0.28)
                .contentShape(Rectangle())
                .onTapGesture { isRightColumnDrawerPresented = false }

            rightColumn
                .frame(width: LayoutMetrics.rightColumnDrawerWidth)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Theme.borderHairline)
                        .frame(width: 1)
                }
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
            RoutingModelProvider.shared.setFocusedProject(nil)
            return
        }

        if selection.didPerformLaunchResume,
           let id = selection.selectedProjectID,
           allProjects.contains(where: { $0.id == id }) {
            RoutingModelProvider.shared.setFocusedProject(id)
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

    /// Files pane always opens at `~` (logged-in user home). Project folders
    /// are optional destinations via the location menu — never forced.
    private func ensureFilesAtUserHome() {
        fileBrowser.setRoot(FileBrowserModel.userHomeURL)
    }

    private var activeProjectFolderURL: URL? {
        guard let project = currentProject else { return nil }
        let url = URL(fileURLWithPath: project.folderPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // Quick chat is already rooted at home — no separate project entry.
        if project.isQuickChat { return nil }
        if url.standardizedFileURL.path == FileBrowserModel.userHomeURL.path { return nil }
        return url
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

/// Top-right stack tabs: Files browser or Apple Reminders (To-Do).
private enum RightTopTab: String, CaseIterable, Identifiable {
    case files
    case todo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: return "Files"
        case .todo: return "To-Do"
        }
    }
}

private struct RightColumnView: View {
    @ObservedObject var fileBrowser: FileBrowserModel
    var previewPresenter: FilePreviewPresenting
    let project: WorkspaceProject?
    /// Optional project working folder for the Files location menu (never auto-forced).
    var projectFolderURL: URL? = nil
    let filesFocused: Bool
    let terminalFocused: Bool
    let onFocusFiles: () -> Void
    let onFocusTerminal: () -> Void
    let onPaneShortcut: (WorkspacePane) -> Void

    /// Top (Files/To-Do) fraction — sc1 keeps the top pane larger than Terminal.
    // Key bumped so sc1 default (Files ~68%) wins over the old 0.5 store.
    @AppStorage("prodigy.rightColumn.filesFraction.v2")
    private var filesFraction = LayoutMetrics.rightColumnFilesDefaultFraction

    @AppStorage("prodigy.rightColumn.topTab")
    private var topTabRaw = RightTopTab.files.rawValue

    @ObservedObject private var reminders = AppleRemindersService.shared

    private var topTab: RightTopTab {
        RightTopTab(rawValue: topTabRaw) ?? .files
    }

    var body: some View {
        // Flush stack with 1pt drag handle (sc1 top pane over Terminal).
        ResizableVStack(
            topFraction: $filesFraction,
            minTop: LayoutMetrics.nestedPaneMinHeight,
            minBottom: LayoutMetrics.nestedPaneMinHeight,
            maxTopFraction: LayoutMetrics.nestedPaneMaxFraction,
            maxBottomFraction: LayoutMetrics.nestedPaneMaxFraction,
            gap: LiquidGlassMetrics.columnDividerWidth,
            tooltip: "Drag to resize Files/To-Do and Terminal"
        ) {
            rightTopPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(perform: onFocusFiles)
                .background(Theme.centerBackground)
        } bottom: {
            TerminalPaneView(
                isFocused: terminalFocused,
                onPaneShortcut: onPaneShortcut
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: onFocusTerminal)
            .background(Theme.terminalBackground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.centerBackground)
    }

    private var rightTopPane: some View {
        VStack(spacing: 0) {
            rightTopTabBar
            Group {
                switch topTab {
                case .files:
                    FileBrowserPaneView(
                        model: fileBrowser,
                        previewPresenter: previewPresenter,
                        projectFolderURL: projectFolderURL,
                        isFocused: filesFocused && topTab == .files,
                        showsChromeHeader: false
                    )
                case .todo:
                    AppleRemindersPaneView(
                        reminders: reminders,
                        isFocused: filesFocused && topTab == .todo
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.centerBackground)
    }

    /// Files | To-Do strip — same chrome language as the bottom Terminal tabs.
    private var rightTopTabBar: some View {
        HStack(spacing: 0) {
            ForEach(RightTopTab.allCases) { tab in
                Button {
                    topTabRaw = tab.rawValue
                    onFocusFiles()
                    if tab == .todo {
                        Task { await reminders.refresh() }
                    }
                } label: {
                    Text(tab.title)
                        .font((topTab == tab ? Font.subheadline.weight(.semibold) : Font.subheadline))
                        .foregroundStyle(topTab == tab ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.clear)
                        .overlay(alignment: .bottom) {
                            if topTab == tab {
                                Rectangle()
                                    .fill(Theme.accent)
                                    .frame(height: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(tab == .files ? "Browse files" : "Apple Reminders (To-Do)")
            }

            Spacer(minLength: 8)

            if topTab == .files {
                Button {
                    fileBrowser.reloadRoot()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(Font.caption.weight(.medium))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Reload folder")
                .disabled(fileBrowser.rootURL == nil)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Theme.centerBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.borderHairline)
                .frame(height: 1)
        }
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

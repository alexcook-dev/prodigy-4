import SwiftData
import SwiftUI

/// Root 4-pane shell: sidebar | center chat/preview | right files/terminal.
///
/// Integrates Wave 1-data (SwiftData), Wave 1-files (lazy file browser), and
/// Wave 1-terminal (SwiftTerm + ⌘1–⌘4 passthrough via WorkspaceFocusController).
struct WorkspaceRootView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var focus: WorkspaceFocusController

    @State private var selection = WorkspaceSelection()
    @State private var showProjectSheet = false
    @StateObject private var fileBrowser = FileBrowserModel()

    @Query(sort: \WorkspaceProject.lastActiveAt, order: .reverse)
    private var allProjects: [WorkspaceProject]

    var body: some View {
        HSplitView {
            SidebarView(
                selection: selection,
                isFocused: focus.focusedPane == .sidebar
            )
            .frame(minWidth: 180, idealWidth: LayoutMetrics.sidebarWidth, maxWidth: 320)
            .layoutPriority(0)
            .contentShape(Rectangle())
            .onTapGesture { focus.focus(.sidebar) }

            CenterPaneView(
                selection: selection,
                fileRootURL: fileBrowser.rootURL,
                isFocused: focus.focusedPane == .chat,
                onCreateProject: { showProjectSheet = true },
                onQuickChat: startQuickChat
            )
            .frame(minWidth: 360)
            .layoutPriority(1)
            .contentShape(Rectangle())
            .onTapGesture { focus.focus(.chat) }

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
            .frame(minWidth: 220, idealWidth: LayoutMetrics.rightColumnWidth, maxWidth: 480)
            .layoutPriority(0)
        }
        .background(Theme.appBackground)
        .preferredColorScheme(nil)
        .focusable()
        .onKeyPress(keys: [.init("1"), .init("2"), .init("3"), .init("4")]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            switch press.key {
            case "1": focus.focus(.sidebar)
            case "2":
                focus.focus(.chat)
                selection.showChat()
            case "3": focus.focus(.files)
            case "4": focus.focus(.terminal)
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
            restoreSelectionIfNeeded()
            rebindFileRoot()
        }
        .onChange(of: allProjects.count) { _, _ in
            restoreSelectionIfNeeded()
        }
        .onChange(of: selection.selectedProjectID) { _, _ in
            rebindFileRoot()
        }
    }

    private var currentProject: WorkspaceProject? {
        guard let id = selection.selectedProjectID else { return nil }
        return allProjects.first { $0.id == id }
    }

    private func restoreSelectionIfNeeded() {
        if let id = selection.selectedProjectID,
           allProjects.contains(where: { $0.id == id }) {
            return
        }
        if let recent = allProjects.first(where: { !$0.archived && !$0.isHiddenFromSidebar })
            ?? allProjects.first(where: { !$0.archived }) {
            selection.selectProject(recent)
            try? modelContext.save()
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

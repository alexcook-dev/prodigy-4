import SwiftData
import SwiftUI

/// Root 4-pane shell matching wireframe proportions:
/// left sidebar (Projects / Agents) | center chat/preview | right (Files / Terminal).
///
/// Combines Wave 1-data (SwiftData selection) with Wave 1-files (lazy file browser + previews).
struct WorkspaceRootView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var selection = WorkspaceSelection()
    @State private var focusedPane: WorkspacePane = .chat
    @State private var showProjectSheet = false
    @StateObject private var fileBrowser = FileBrowserModel()

    @Query(sort: \WorkspaceProject.lastActiveAt, order: .reverse)
    private var allProjects: [WorkspaceProject]

    var body: some View {
        HSplitView {
            SidebarView(
                selection: selection,
                isFocused: focusedPane == .sidebar
            )
            .frame(minWidth: 180, idealWidth: LayoutMetrics.sidebarWidth, maxWidth: 320)
            .layoutPriority(0)

            CenterPaneView(
                selection: selection,
                fileRootURL: fileBrowser.rootURL,
                isFocused: focusedPane == .chat,
                onCreateProject: { showProjectSheet = true },
                onQuickChat: startQuickChat
            )
            .frame(minWidth: 360)
            .layoutPriority(1)

            RightColumnView(
                fileBrowser: fileBrowser,
                previewPresenter: selection,
                project: currentProject,
                filesFocused: focusedPane == .files,
                terminalFocused: focusedPane == .terminal
            )
            .frame(minWidth: 220, idealWidth: LayoutMetrics.rightColumnWidth, maxWidth: 480)
            .layoutPriority(0)
        }
        .background(Theme.appBackground)
        .preferredColorScheme(nil) // follow system Light/Dark (T15)
        .focusable()
        .onKeyPress(keys: [.init("1"), .init("2"), .init("3"), .init("4")]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            switch press.key {
            case "1": focusedPane = .sidebar
            case "2":
                focusedPane = .chat
                selection.showChat()
            case "3": focusedPane = .files
            case "4": focusedPane = .terminal
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

    /// Prefer the last-active non-archived, visible Project. True first-run
    /// (zero Projects) leaves selection empty so Center shows the greeting.
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

    /// Bind the file browser to the active Project's working folder.
    private func rebindFileRoot() {
        if let path = currentProject?.folderPath {
            fileBrowser.setRoot(URL(fileURLWithPath: path, isDirectory: true))
        } else {
            fileBrowser.setRoot(nil)
        }
    }

    /// T11: quick chat auto-creates a real hidden Project (not a second identity model).
    private func startQuickChat() {
        do {
            let project = try ProjectFactory.createQuickChat(in: modelContext)
            try modelContext.save()
            selection.selectProject(project)
            focusedPane = .chat
            selection.showChat()
        } catch {
            // Surface via sheet fallback if folder creation fails.
            showProjectSheet = true
        }
    }
}

enum WorkspacePane: Hashable {
    case sidebar
    case chat
    case files
    case terminal
}

// MARK: - Right column

private struct RightColumnView: View {
    @ObservedObject var fileBrowser: FileBrowserModel
    var previewPresenter: FilePreviewPresenting
    let project: WorkspaceProject?
    let filesFocused: Bool
    let terminalFocused: Bool

    var body: some View {
        VSplitView {
            FileBrowserPaneView(
                model: fileBrowser,
                previewPresenter: previewPresenter,
                isFocused: filesFocused
            )
            .frame(minHeight: 120)

            TerminalPaneView(
                projectFolderPath: project?.folderPath,
                isFocused: terminalFocused
            )
            .frame(minHeight: 100)
        }
        .background(Theme.appBackground)
    }
}

#Preview("Workspace shell") {
    WorkspaceRootView()
        .frame(width: 1200, height: 760)
        .modelContainer(for: [
            WorkspaceProject.self,
            Agent.self,
            ChatThread.self,
            Message.self,
        ], inMemory: true)
}

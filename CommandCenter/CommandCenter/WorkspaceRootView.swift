import SwiftUI

/// Root 4-pane shell matching wireframe proportions:
/// left sidebar (Projects / Agents) | center chat/preview | right (Files / Terminal).
///
/// File browser (T6) is live: lazy FileManager tree + center-pane preview tabs.
/// Chat body / provider / terminal internals remain later waves.
struct WorkspaceRootView: View {
    /// Which pane currently owns keyboard focus (⌘1–⌘4 will fully land with T10).
    @State private var focusedPane: WorkspacePane = .chat

    /// Placeholder selection — real Project/Agent models arrive with T3.
    @State private var selectedProjectID: String? = "website-redesign"
    @State private var selectedAgentID: String?

    /// File tree state — root rebinds when Project working folders land (T3/T11).
    @StateObject private var fileBrowser = FileBrowserModel()

    /// Interim center-pane preview host.
    /// TODO(Wave 3 / T5): replace with the real chat controller conforming to
    /// `FilePreviewPresenting` so file selection flips the genuine chat tab bar.
    @StateObject private var previewSession = FilePreviewSession()

    var body: some View {
        HSplitView {
            SidebarView(
                selectedProjectID: $selectedProjectID,
                selectedAgentID: $selectedAgentID,
                isFocused: focusedPane == .sidebar
            )
            .frame(minWidth: 180, idealWidth: LayoutMetrics.sidebarWidth, maxWidth: 320)
            .layoutPriority(0)

            CenterPaneView(
                previewSession: previewSession,
                fileRootURL: fileBrowser.rootURL,
                isFocused: focusedPane == .chat
            )
            .frame(minWidth: 360)
            .layoutPriority(1)

            RightColumnView(
                fileBrowser: fileBrowser,
                previewPresenter: previewSession,
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
            case "1":
                focusedPane = .sidebar
            case "2":
                // ⌘2 = unconditional "go to Chat tab" (PLAN.md keyboard contract).
                focusedPane = .chat
                previewSession.activateChatTab()
            case "3":
                focusedPane = .files
            case "4":
                focusedPane = .terminal
            default:
                return .ignored
            }
            return .handled
        }
        .onAppear {
            // Until T3/T11 bind a Project working folder, root at a sensible
            // directory so the browser is usable for dogfooding the tree.
            rebindFileRoot(forProjectID: selectedProjectID)
        }
        .onChange(of: selectedProjectID) { _, newID in
            // Placeholder mapping — real Project.workingDirectory arrives with T3/T11.
            rebindFileRoot(forProjectID: newID)
        }
    }

    /// Temporary root mapping until SwiftData Project models land.
    private func rebindFileRoot(forProjectID id: String?) {
        guard id != nil else {
            fileBrowser.setRoot(nil)
            return
        }
        // Prefer ~/Projects if it exists; otherwise stay on home.
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects", isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: projects.path, isDirectory: &isDir),
           isDir.boolValue {
            fileBrowser.setRoot(projects)
        } else {
            fileBrowser.setRoot(FileManager.default.homeDirectoryForCurrentUser)
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

            TerminalPaneView(isFocused: terminalFocused)
                .frame(minHeight: 100)
        }
        .background(Theme.appBackground)
    }
}

#Preview("Workspace shell") {
    WorkspaceRootView()
        .frame(width: 1200, height: 760)
}

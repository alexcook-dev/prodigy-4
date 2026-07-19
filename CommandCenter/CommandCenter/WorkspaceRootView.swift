import SwiftUI

/// Root 4-pane shell matching wireframe proportions:
/// left sidebar (Projects / Agents) | center chat/preview | right (Files / Terminal).
///
/// Internals for chat, files, and terminal are placeholders — later waves.
struct WorkspaceRootView: View {
    /// Which pane currently owns keyboard focus (⌘1–⌘4 will wire later).
    @State private var focusedPane: WorkspacePane = .chat

    /// Placeholder selection — real Project/Agent models arrive with T3.
    @State private var selectedProjectID: String? = "website-redesign"
    @State private var selectedAgentID: String?

    var body: some View {
        HSplitView {
            SidebarView(
                selectedProjectID: $selectedProjectID,
                selectedAgentID: $selectedAgentID,
                isFocused: focusedPane == .sidebar
            )
            .frame(minWidth: 180, idealWidth: LayoutMetrics.sidebarWidth, maxWidth: 320)
            .layoutPriority(0)

            CenterPaneView(isFocused: focusedPane == .chat)
                .frame(minWidth: 360)
                .layoutPriority(1)

            RightColumnView(
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
            case "2": focusedPane = .chat
            case "3": focusedPane = .files
            case "4": focusedPane = .terminal
            default: return .ignored
            }
            return .handled
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
    let filesFocused: Bool
    let terminalFocused: Bool

    var body: some View {
        VSplitView {
            FileBrowserPaneView(isFocused: filesFocused)
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

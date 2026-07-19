import SwiftUI

/// Root 4-pane shell matching wireframe proportions:
/// left sidebar (Projects / Agents) | center chat/preview | right (Files / Terminal).
///
/// ⌘1–⌘4 pane focus (T10): works both via SwiftUI key press (when a SwiftUI
/// view is focused) and via main-menu key equivalents (when the AppKit
/// terminal is first responder and `KeyPassthroughTerminalView` returns false
/// for those chords).
struct WorkspaceRootView: View {
    @EnvironmentObject private var focus: WorkspaceFocusController

    /// Placeholder selection — real Project/Agent models arrive with T3.
    @State private var selectedProjectID: String? = "website-redesign"
    @State private var selectedAgentID: String?

    var body: some View {
        HSplitView {
            SidebarView(
                selectedProjectID: $selectedProjectID,
                selectedAgentID: $selectedAgentID,
                isFocused: focus.focusedPane == .sidebar
            )
            .frame(minWidth: 180, idealWidth: LayoutMetrics.sidebarWidth, maxWidth: 320)
            .layoutPriority(0)
            .contentShape(Rectangle())
            .onTapGesture { focus.focus(.sidebar) }

            CenterPaneView(isFocused: focus.focusedPane == .chat)
                .frame(minWidth: 360)
                .layoutPriority(1)
                .contentShape(Rectangle())
                .onTapGesture { focus.focus(.chat) }

            RightColumnView(
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
        .preferredColorScheme(nil) // follow system Light/Dark (T15)
        .focusable()
        .onKeyPress(keys: [.init("1"), .init("2"), .init("3"), .init("4")]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            switch press.key {
            case "1": focus.focus(.sidebar)
            case "2": focus.focus(.chat)
            case "3": focus.focus(.files)
            case "4": focus.focus(.terminal)
            default: return .ignored
            }
            return .handled
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

    /// Keyboard digit for ⌘N (1…4).
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
    let filesFocused: Bool
    let terminalFocused: Bool
    let onFocusFiles: () -> Void
    let onFocusTerminal: () -> Void
    let onPaneShortcut: (WorkspacePane) -> Void

    var body: some View {
        VSplitView {
            FileBrowserPaneView(isFocused: filesFocused)
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
}

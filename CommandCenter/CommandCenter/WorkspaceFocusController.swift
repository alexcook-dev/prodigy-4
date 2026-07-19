import Combine
import Foundation

/// Shared focus owner for ⌘1–⌘4 pane switching.
///
/// Lives outside individual panes so (a) SwiftUI `.onKeyPress` and (b) main-menu
/// key equivalents installed for when an AppKit `TerminalView` is first
/// responder both update the same source of truth.
///
/// ⌘2 is unconditional "go to Chat tab" (PLAN.md Responsive & Accessibility) —
/// `chatTabActivationToken` bumps so the root view can call `showChat()` even
/// when the Navigate menu only reaches this controller (Terminal first-responder).
@MainActor
final class WorkspaceFocusController: ObservableObject {
    @Published var focusedPane: WorkspacePane = .chat
    /// Incremented whenever Chat is focused via ⌘2 / Navigate → Chat.
    @Published private(set) var chatTabActivationToken: UInt = 0

    func focus(_ pane: WorkspacePane) {
        focusedPane = pane
        if pane == .chat {
            chatTabActivationToken &+= 1
        }
    }
}

import Combine
import Foundation

/// Shared focus owner for ⌘1–⌘4 pane switching.
///
/// Lives outside individual panes so (a) SwiftUI `.onKeyPress` and (b) main-menu
/// key equivalents installed for when an AppKit `TerminalView` is first
/// responder both update the same source of truth.
///
/// **Important:** pane focus is not the same as Chat *tab* activation.
/// Clicking the center column (including the Safari WebView) only focuses the
/// center pane — it must not flip `activeSurface` to Chat. Only ⌘2 / Navigate →
/// Chat / explicit Chat-tab clicks should call `activateChatTab()`.
@MainActor
final class WorkspaceFocusController: ObservableObject {
    @Published var focusedPane: WorkspacePane = .chat
    /// Incremented only by `activateChatTab()` (⌘2 / Navigate → Chat).
    /// `WorkspaceRootView` observes this and calls `selection.showChat()`.
    @Published private(set) var chatTabActivationToken: UInt = 0

    /// Move keyboard/pane focus only. Does **not** switch the center surface
    /// away from Safari / file preview.
    func focus(_ pane: WorkspacePane) {
        focusedPane = pane
    }

    /// Unconditional "go to Chat tab" (PLAN.md Responsive & Accessibility).
    /// Use for ⌘2 and the Navigate menu — not for generic center-pane clicks.
    func activateChatTab() {
        focusedPane = .chat
        chatTabActivationToken &+= 1
    }
}

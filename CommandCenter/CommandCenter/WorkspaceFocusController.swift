import Combine
import Foundation

/// Shared focus owner for ⌘1–⌘4 pane switching.
///
/// Lives outside individual panes so (a) SwiftUI `.onKeyPress` and (b) main-menu
/// key equivalents installed for when an AppKit `TerminalView` is first
/// responder both update the same source of truth.
@MainActor
final class WorkspaceFocusController: ObservableObject {
    @Published var focusedPane: WorkspacePane = .chat

    func focus(_ pane: WorkspacePane) {
        focusedPane = pane
    }
}

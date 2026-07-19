import SwiftData
import SwiftUI

/// Personal Mac command center — shell scaffold (T2) + semantic colors (T15)
/// + embedded SwiftTerm terminal (T7/T10).
///
/// Persistence is SwiftData (per Constraints); concrete models land in a later
/// wave. The empty container is wired now so later models drop in without
/// rewiring app entry.
@main
struct CommandCenterApp: App {
    @StateObject private var focus = WorkspaceFocusController()

    var body: some Scene {
        WindowGroup {
            WorkspaceRootView()
                .environmentObject(focus)
                .frame(
                    minWidth: LayoutMetrics.minWindowWidth,
                    minHeight: LayoutMetrics.minWindowHeight
                )
        }
        .defaultSize(
            width: LayoutMetrics.defaultWindowWidth,
            height: LayoutMetrics.defaultWindowHeight
        )
        .modelContainer(for: [], isUndoEnabled: false)
        // Unsandboxed personal build; ad-hoc signing is configured in the
        // Xcode project (CODE_SIGN_IDENTITY="-", ENABLE_APP_SANDBOX=NO).
        .commands {
            CommandGroup(replacing: .newItem) {}
            // Pane switching — registered as menu key-equivalents so ⌘1–⌘4
            // still work when the AppKit TerminalView is first responder.
            // KeyPassthroughTerminalView returns false for these chords so
            // AppKit delivers them here (T10 / Premise 1).
            CommandMenu("Navigate") {
                ForEach(WorkspacePane.allCases, id: \.self) { pane in
                    Button(pane.menuTitle) {
                        focus.focus(pane)
                    }
                    .keyboardShortcut(
                        KeyEquivalent(pane.shortcutDigit),
                        modifiers: .command
                    )
                }
            }
        }
    }
}

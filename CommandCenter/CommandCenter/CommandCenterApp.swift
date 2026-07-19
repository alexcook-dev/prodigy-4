import SwiftData
import SwiftUI

/// Personal Mac command center — shell (T2) + colors (T15) + SwiftData (T3/T11/T12)
/// + file browser (T6) + SwiftTerm terminal (T7/T10).
@main
struct CommandCenterApp: App {
    @StateObject private var focus = WorkspaceFocusController()

    /// Shared schema for Projects, Agents, Threads, Messages.
    private var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            WorkspaceProject.self,
            Agent.self,
            ChatThread.self,
            Message.self,
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: [memory])
        }
    }()

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
        .modelContainer(sharedModelContainer)
        // Unsandboxed personal build; ad-hoc signing is configured in the
        // Xcode project (CODE_SIGN_IDENTITY="-", ENABLE_APP_SANDBOX=NO).
        .commands {
            CommandGroup(replacing: .newItem) {}
            // Pane switching — menu key-equivalents so ⌘1–⌘4 still work when
            // the AppKit TerminalView is first responder (T10 / Premise 1).
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

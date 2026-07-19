import SwiftData
import SwiftUI

/// Personal Mac command center — shell (T2) + semantic colors (T15)
/// + SwiftData models / Projects+Agents (T3) + creation (T11) + archive (T12).
@main
struct CommandCenterApp: App {
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
            // Fallback: in-memory so a corrupt store never bricks launch.
            // User can recover via "Reset local data" later (PLAN interaction states).
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            // If even memory fails, crash with a clear message — nothing else to do.
            return try! ModelContainer(for: schema, configurations: [memory])
        }
    }()

    var body: some Scene {
        WindowGroup {
            WorkspaceRootView()
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
        }
    }
}

import SwiftData
import SwiftUI

/// Personal Mac command center — shell scaffold (T2) + semantic colors (T15).
///
/// Persistence is SwiftData (per Constraints); concrete models land in a later
/// wave. The empty container is wired now so later models drop in without
/// rewiring app entry.
@main
struct CommandCenterApp: App {
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
        .modelContainer(for: [], isUndoEnabled: false)
        // Unsandboxed personal build; ad-hoc signing is configured in the
        // Xcode project (CODE_SIGN_IDENTITY="-", ENABLE_APP_SANDBOX=NO).
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

import SwiftData
import SwiftUI

/// Personal Mac command center — shell scaffold (T2) + semantic colors (T15)
/// + window layout behavior (T16).
///
/// Persistence is SwiftData (per Constraints); concrete models land in a later
/// wave. The empty container is wired now so later models drop in without
/// rewiring app entry.
@main
struct CommandCenterApp: App {
    var body: some Scene {
        WindowGroup {
            WorkspaceRootView()
                // Soft floor only — PLAN.md: no hard minimum window size.
                // Windows must tile to ~650–700px for daily use (T16).
                .frame(
                    minWidth: LayoutMetrics.minWindowWidth,
                    minHeight: LayoutMetrics.minWindowHeight
                )
        }
        .defaultSize(
            width: LayoutMetrics.defaultWindowWidth,
            height: LayoutMetrics.defaultWindowHeight
        )
        // Restore window frame/position via AppKit stock behavior.
        .defaultPosition(.center)
        .modelContainer(for: [], isUndoEnabled: false)
        // Unsandboxed personal build; ad-hoc signing is configured in the
        // Xcode project (CODE_SIGN_IDENTITY="-", ENABLE_APP_SANDBOX=NO).
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

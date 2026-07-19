import SwiftData
import SwiftUI

extension Notification.Name {
    static let prodigyOpenSettings = Notification.Name("prodigy.openSettings")
}

/// Personal Mac command center — shell (T2) + colors (T15) + SwiftData (T3/T11/T12)
/// + file browser (T6) + SwiftTerm terminal (T7/T10) + Claude CLI provider (T4/T9)
/// + chat UI / streaming markdown / error banners (T5/T13)
/// + launch resume of last-active Project/thread (T14).
@main
struct CommandCenterApp: App {
    @StateObject private var focus = WorkspaceFocusController()
    @AppStorage(AppStorageKey.appearance) private var appearanceRaw = AppAppearance.system.rawValue

    private var preferredScheme: ColorScheme? {
        (AppAppearance(rawValue: appearanceRaw) ?? .system).colorScheme
    }

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
                // San Francisco (system font) for the whole app — Apple HIG default.
                .font(AppTypography.body)
                .preferredColorScheme(preferredScheme)
                .frame(
                    minWidth: LayoutMetrics.minWindowWidth,
                    minHeight: LayoutMetrics.minWindowHeight
                )
                // Full-window Liquid Glass backdrop — gaps between cards sample this
                // in windowed **and** fullscreen (solid fills go black in FS spaces).
                .containerBackground(for: .window) {
                    LiquidGlassAmbientBackground()
                }
                .background {
                    // Also paint glass inside the content hierarchy so FS transitions
                    // that ignore containerBackground still show frosted interstitials.
                    LiquidGlassAmbientBackground()
                        .ignoresSafeArea()
                }
                .background(LiquidGlassWindowChrome())
        }
        .defaultSize(
            width: LayoutMetrics.defaultWindowWidth,
            height: LayoutMetrics.defaultWindowHeight
        )
        // Unified titlebar composites with glass content.
        .windowStyle(.hiddenTitleBar)
        .modelContainer(sharedModelContainer)
        // Unsandboxed personal build; ad-hoc signing is configured in the
        // Xcode project (CODE_SIGN_IDENTITY="-", ENABLE_APP_SANDBOX=NO).
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .prodigyOpenSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
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

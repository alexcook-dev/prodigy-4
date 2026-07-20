import SwiftData
import SwiftUI

extension Notification.Name {
    static let prodigyOpenSettings = Notification.Name("prodigy.openSettings")
    static let prodigyCheckForUpdates = Notification.Name("prodigy.checkForUpdates")
    /// Close the active center tab (⌘W) — handled by `WorkspaceRootView`.
    static let prodigyCloseActiveTab = Notification.Name("prodigy.closeActiveTab")
}

/// Personal Mac command center — shell (T2) + colors (T15) + SwiftData (T3/T11/T12)
/// + file browser (T6) + SwiftTerm terminal (T7/T10) + Claude CLI provider (T4/T9)
/// + chat UI / streaming markdown / error banners (T5/T13)
/// + launch resume of last-active Project/thread (T14).
@main
struct CommandCenterApp: App {
    @StateObject private var focus = WorkspaceFocusController()
    @AppStorage(AppStorageKey.appearance) private var appearanceRaw = AppAppearance.system.rawValue
    @AppStorage(AppStorageKey.contentZoom) private var contentZoom = ContentZoom.default

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
                // Native system type (SF Pro) — no custom point sizes.
                .preferredColorScheme(preferredScheme)
                .prodigyContentZoom(contentZoom)
                .frame(
                    minWidth: LayoutMetrics.minWindowWidth,
                    minHeight: LayoutMetrics.minWindowHeight
                )
                // sc1: solid app chrome (flush columns), not floating glass cards.
                .containerBackground(for: .window) {
                    Theme.appBackground
                }
                .background(Theme.appBackground)
                .background(LiquidGlassWindowChrome())
                // Ensure first open sizes to ~92%×88% of the active display.
                .background(WindowScreenSizer())
        }
        .defaultSize(
            width: LayoutMetrics.defaultWindowSize().width,
            height: LayoutMetrics.defaultWindowSize().height
        )
        // Titlebar over content so columns reach the top edge (Cursor-style).
        .windowStyle(.hiddenTitleBar)
        .modelContainer(sharedModelContainer)
        // Unsandboxed personal build; ad-hoc signing is configured in the
        // Xcode project (CODE_SIGN_IDENTITY="-", ENABLE_APP_SANDBOX=NO).
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    NotificationCenter.default.post(name: .prodigyCheckForUpdates, object: nil)
                }
            }
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
                        // Chat menu item = go to Chat tab (not just pane focus).
                        if pane == .chat {
                            focus.activateChatTab()
                        } else {
                            focus.focus(pane)
                        }
                    }
                    .keyboardShortcut(
                        KeyEquivalent(pane.shortcutDigit),
                        modifiers: .command
                    )
                }
                Divider()
                Button("Close Tab") {
                    NotificationCenter.default.post(name: .prodigyCloseActiveTab, object: nil)
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            // Content zoom — browser-style ⌘+/⌘-/⌘0 (also ⌘=).
            CommandMenu("View") {
                Button("Zoom In") {
                    contentZoom = ContentZoom.zoomIn(contentZoom)
                }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(contentZoom >= ContentZoom.maximum - 0.001)

                // Same action for ⌘+ (Shift+= on US keyboards).
                Button("Zoom In") {
                    contentZoom = ContentZoom.zoomIn(contentZoom)
                }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(contentZoom >= ContentZoom.maximum - 0.001)

                Button("Zoom Out") {
                    contentZoom = ContentZoom.zoomOut(contentZoom)
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(contentZoom <= ContentZoom.minimum + 0.001)

                Button("Actual Size") {
                    contentZoom = ContentZoom.default
                }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(abs(contentZoom - ContentZoom.default) < 0.001)

                Divider()

                Text("Zoom: \(ContentZoom.percentLabel(contentZoom))")
            }
        }
    }
}

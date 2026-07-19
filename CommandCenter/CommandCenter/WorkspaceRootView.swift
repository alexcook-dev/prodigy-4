import SwiftUI

/// Root 4-pane shell matching wireframe proportions:
/// left sidebar (Projects / Agents) | center chat/preview | right (Files / Terminal).
///
/// T16 window behavior:
/// - Draggable `NSSplitView` dividers with width persistence (`autosaveName`)
/// - Below `rightColumnCollapseBreakpoint`, the right column becomes an overlay/drawer
///   (Mail.app / Xcode pattern) — no hard minimum window size
/// - Center chat content caps at `maxReadingWidth` (handled in `CenterPaneView`)
///
/// Internals for chat, files, and terminal remain placeholders — later waves.
struct WorkspaceRootView: View {
    /// Which pane currently owns keyboard focus (⌘1–⌘4).
    @State private var focusedPane: WorkspacePane = .chat

    /// Placeholder selection — real Project/Agent models arrive with T3.
    @State private var selectedProjectID: String? = "website-redesign"
    @State private var selectedAgentID: String?

    /// Overlay drawer for Files/Terminal when the window is below the collapse breakpoint.
    @State private var isRightColumnDrawerPresented = false

    /// Live window content width — drives the narrow-width collapse.
    @State private var windowWidth: CGFloat = LayoutMetrics.defaultWindowWidth

    private var isNarrow: Bool {
        windowWidth < LayoutMetrics.rightColumnCollapseBreakpoint
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            mainSplit
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if isNarrow && isRightColumnDrawerPresented {
                rightColumnDrawer
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(Theme.appBackground)
        .background(
            GeometryReader { geo in
                Color.clear
                    .preference(key: WindowWidthPreferenceKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(WindowWidthPreferenceKey.self) { width in
            windowWidth = width
        }
        .onChange(of: isNarrow) { _, narrow in
            // Leaving narrow mode: drawer content is back in the column — dismiss.
            if !narrow {
                isRightColumnDrawerPresented = false
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isRightColumnDrawerPresented)
        .preferredColorScheme(nil) // follow system Light/Dark (T15)
        .toolbar {
            if isNarrow {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isRightColumnDrawerPresented.toggle()
                    } label: {
                        Label(
                            isRightColumnDrawerPresented
                                ? "Hide Files & Terminal"
                                : "Show Files & Terminal",
                            systemImage: isRightColumnDrawerPresented
                                ? "sidebar.trailing"
                                : "rectangle.righthalf.inset.filled"
                        )
                    }
                    .help("Toggle Files & Terminal panel")
                }
            }
        }
        .focusable()
        .onKeyPress(keys: [.init("1"), .init("2"), .init("3"), .init("4")]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            switch press.key {
            case "1":
                focusedPane = .sidebar
            case "2":
                focusedPane = .chat
            case "3":
                focusedPane = .files
                openRightColumnIfCollapsed()
            case "4":
                focusedPane = .terminal
                openRightColumnIfCollapsed()
            default:
                return .ignored
            }
            return .handled
        }
    }

    // MARK: - Main split

    @ViewBuilder
    private var mainSplit: some View {
        if isNarrow {
            // Sidebar | Center — right column lives in the overlay drawer.
            PersistableHSplitView(
                autosaveName: "CommandCenter.Workspace.Narrow",
                panes: [
                    sidebarPane,
                    centerPane,
                ]
            )
        } else {
            // Sidebar | Center | Right column
            PersistableHSplitView(
                autosaveName: "CommandCenter.Workspace.Wide",
                panes: [
                    sidebarPane,
                    centerPane,
                    rightPane,
                ]
            )
        }
    }

    private var sidebarPane: PersistableHSplitView.Pane {
        PersistableHSplitView.Pane(
            minWidth: LayoutMetrics.sidebarMinWidth,
            idealWidth: LayoutMetrics.sidebarWidth,
            maxWidth: LayoutMetrics.sidebarMaxWidth,
            holdingPriority: .defaultHigh
        ) {
            SidebarView(
                selectedProjectID: $selectedProjectID,
                selectedAgentID: $selectedAgentID,
                isFocused: focusedPane == .sidebar
            )
        }
    }

    private var centerPane: PersistableHSplitView.Pane {
        PersistableHSplitView.Pane(
            minWidth: LayoutMetrics.centerMinWidth,
            idealWidth: nil,
            maxWidth: nil,
            holdingPriority: .defaultLow
        ) {
            CenterPaneView(isFocused: focusedPane == .chat)
        }
    }

    private var rightPane: PersistableHSplitView.Pane {
        PersistableHSplitView.Pane(
            minWidth: LayoutMetrics.rightColumnMinWidth,
            idealWidth: LayoutMetrics.rightColumnWidth,
            maxWidth: LayoutMetrics.rightColumnMaxWidth,
            holdingPriority: .defaultHigh
        ) {
            RightColumnView(
                filesFocused: focusedPane == .files,
                terminalFocused: focusedPane == .terminal
            )
        }
    }

    // MARK: - Right-column drawer (narrow widths)

    private var rightColumnDrawer: some View {
        ZStack(alignment: .trailing) {
            // Scrim — tap dismisses, matching Mail/Xcode inspector overlays.
            Theme.deepest.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    isRightColumnDrawerPresented = false
                }
                .accessibilityLabel("Dismiss Files and Terminal")
                .accessibilityAddTraits(.isButton)

            VStack(spacing: 0) {
                drawerChrome
                RightColumnView(
                    filesFocused: focusedPane == .files,
                    terminalFocused: focusedPane == .terminal
                )
            }
            .frame(width: LayoutMetrics.rightColumnDrawerWidth)
            .frame(maxHeight: .infinity)
            .background(Theme.appBackground)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Theme.borderStructural)
                    .frame(width: 1)
            }
            .shadow(color: .black.opacity(0.28), radius: 18, x: -4, y: 0)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Files and Terminal")
        }
    }

    private var drawerChrome: some View {
        HStack(spacing: 8) {
            Text("Files & Terminal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)

            Spacer()

            Button {
                isRightColumnDrawerPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close panel")
            .accessibilityLabel("Close Files and Terminal")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.sidebarBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.borderHairline)
                .frame(height: 1)
        }
    }

    private func openRightColumnIfCollapsed() {
        // When the window is narrow, ⌘3/⌘4 should surface the drawer rather than
        // focusing an off-screen column.
        if isNarrow {
            isRightColumnDrawerPresented = true
        }
    }
}

enum WorkspacePane: Hashable {
    case sidebar
    case chat
    case files
    case terminal
}

// MARK: - Right column

struct RightColumnView: View {
    let filesFocused: Bool
    let terminalFocused: Bool

    var body: some View {
        VSplitView {
            FileBrowserPaneView(isFocused: filesFocused)
                .frame(minHeight: 120)

            TerminalPaneView(isFocused: terminalFocused)
                .frame(minHeight: 100)
        }
        .background(Theme.appBackground)
    }
}

// MARK: - Window width tracking

private struct WindowWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = LayoutMetrics.defaultWindowWidth

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#Preview("Workspace shell — wide") {
    WorkspaceRootView()
        .frame(width: 1200, height: 760)
}

#Preview("Workspace shell — narrow (~650)") {
    WorkspaceRootView()
        .frame(width: 650, height: 700)
}

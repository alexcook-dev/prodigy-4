import SwiftUI

/// Bottom-right pane tabs: Setup (placeholder) · TextEdit · Terminal.
private enum BottomRightTab: String, CaseIterable, Identifiable {
    case setup
    case textEdit
    case terminal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .setup: return "Setup"
        case .textEdit: return "TextEdit"
        case .terminal: return "Terminal"
        }
    }
}

/// Bottom-right terminal panel: SwiftTerm PTY shell (T7) + keyboard passthrough (T10),
/// plus a **TextEdit** tab for document editing (open/save like macOS TextEdit).
///
/// Also reused for **center-column terminal tabs** (`showsChromeHeader: false` hides
/// the Setup/TextEdit/Terminal strip so the center tab bar is the only chrome).
///
/// Failure state (PLAN.md Constraints / wf-3 #5): exited shell shows a visible
/// "process ended" bar with Restart — never a frozen pane.
struct TerminalPaneView: View {
    var isFocused: Bool = false
    var onPaneShortcut: ((WorkspacePane) -> Void)?
    /// Initial shell cwd (user home by default).
    var initialWorkingDirectory: String? = nil
    /// When false, omit the right-column Setup/TextEdit/Terminal strip (center tabs).
    var showsChromeHeader: Bool = true
    /// Optional title callback when the shell cwd/title changes (center tab label).
    var onTitleChange: ((String) -> Void)? = nil
    /// Default folder for TextEdit Open/Save (project folder or Documents).
    var textEditDefaultDirectory: URL? = nil

    @StateObject private var session = TerminalSessionController()
    @StateObject private var textDocument = TextEditDocumentModel()
    @AppStorage("prodigy.rightColumn.bottomTab")
    private var bottomTabRaw = BottomRightTab.terminal.rawValue

    private var bottomTab: BottomRightTab {
        BottomRightTab(rawValue: bottomTabRaw) ?? .terminal
    }

    /// Whether this instance's terminal should accept keyboard/mouse.
    /// Center-column tabs (`showsChromeHeader == false`) must ignore the
    /// bottom-right TextEdit/Setup selection stored in AppStorage.
    private var terminalAcceptsInput: Bool {
        if showsChromeHeader {
            return isFocused && bottomTab == .terminal
        }
        return isFocused
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsChromeHeader {
                panelHeader
                // Keep Terminal + TextEdit mounted so switching tabs never drops
                // the PTY or unsaved editor state.
                ZStack {
                    terminalStack
                        .opacity(bottomTab == .terminal ? 1 : 0)
                        .allowsHitTesting(terminalAcceptsInput)
                        .accessibilityHidden(bottomTab != .terminal)

                    TextEditPaneView(
                        document: textDocument,
                        isFocused: isFocused && bottomTab == .textEdit
                    )
                    .opacity(bottomTab == .textEdit ? 1 : 0)
                    .allowsHitTesting(bottomTab == .textEdit)
                    .accessibilityHidden(bottomTab != .textEdit)

                    if bottomTab == .setup {
                        setupPlaceholder
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                centerSessionHeader
                terminalStack
                    .allowsHitTesting(terminalAcceptsInput)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(bottomTab == .terminal || !showsChromeHeader
            ? Theme.terminalBackground
            : Theme.centerBackground)
        .onAppear {
            // Only seed cwd before first shell start — never reset on tab re-select.
            if !session.isProcessRunning, let initialWorkingDirectory {
                session.setInitialWorkingDirectory(initialWorkingDirectory)
            }
            if let textEditDefaultDirectory {
                textDocument.defaultDirectory = textEditDefaultDirectory
            }
        }
        .onChange(of: textEditDefaultDirectory) { _, url in
            if let url {
                textDocument.defaultDirectory = url
            }
        }
        .onChange(of: session.headerTitle) { _, title in
            onTitleChange?(title)
        }
    }

    private var terminalStack: some View {
        VStack(spacing: 0) {
            terminalBody
            if session.showsProcessEndedBar {
                processEndedBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.terminalBackground)
    }

    /// Compact header for center-column terminal tabs.
    private var centerSessionHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal.fill")
                .font(Font.caption)
                .foregroundStyle(Theme.textTertiary)
            Text(session.headerTitle)
                .font(Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if session.isProcessRunning {
                Circle()
                    .fill(Theme.statusDone)
                    .frame(width: 6, height: 6)
                    .help("Shell running")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.centerBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.borderHairline)
                .frame(height: 1)
        }
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack(spacing: 0) {
            ForEach(BottomRightTab.allCases) { tab in
                Button {
                    bottomTabRaw = tab.rawValue
                } label: {
                    Text(tab.title)
                        .font((bottomTab == tab ? Font.subheadline.weight(.semibold) : Font.subheadline))
                        .foregroundStyle(bottomTab == tab ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.clear)
                        .overlay(alignment: .bottom) {
                            if bottomTab == tab {
                                Rectangle()
                                    .fill(Theme.accent)
                                    .frame(height: 2)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tabHelp(tab))
            }

            if bottomTab == .terminal {
                Button {
                    // Reserved for multi-terminal sessions later.
                } label: {
                    Image(systemName: "plus")
                        .font(Font.caption.weight(.medium))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New terminal (coming soon)")
            }

            Spacer(minLength: 8)

            if bottomTab == .terminal {
                Text(session.headerTitle)
                    .font(Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            } else if bottomTab == .textEdit {
                Text(textDocument.windowTitle)
                    .font(Font.caption)
                    .foregroundStyle(textDocument.isDirty ? Theme.accentText : Theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Theme.centerBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.borderHairline)
                .frame(height: 1)
        }
    }

    private func tabHelp(_ tab: BottomRightTab) -> String {
        switch tab {
        case .setup: return "Setup notes (coming soon)"
        case .textEdit: return "TextEdit — open, edit, and save documents"
        case .terminal: return "Terminal shell"
        }
    }

    private var setupPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("Setup")
                .font(Font.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Project setup notes will live here.\nUse TextEdit for freeform notes in the meantime.")
                .font(Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Open TextEdit") {
                bottomTabRaw = BottomRightTab.textEdit.rawValue
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .background(Theme.centerBackground)
    }

    // MARK: - Terminal body

    private var terminalBody: some View {
        TerminalViewRepresentable(
            session: session,
            isFocused: terminalAcceptsInput,
            onPaneShortcut: onPaneShortcut
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Dim the buffer when the shell has exited so the dead state is obvious
        // even before the eye hits the process-ended bar (wf-3 #5).
        .opacity(session.isProcessRunning ? 1.0 : 0.55)
        // Allow clicks even while restarting so the user can focus after shell start.
        .allowsHitTesting(session.isProcessRunning || terminalAcceptsInput)
        .accessibilityLabel("Terminal")
        .accessibilityValue(session.isProcessRunning ? "Shell running" : session.processEndedMessage)
    }

    // MARK: - Process ended (T7)

    private var processEndedBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Font.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)

            Text(session.processEndedMessage)
                .font(Font.subheadline)
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: 8)

            Button {
                session.requestRestart()
            } label: {
                Text("Restart shell ⏎")
                    .font(Font.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glass)
            .help("Restart the shell")
            .accessibilityLabel("Restart shell")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.elevatedSurface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.borderStructural)
                .frame(height: 1)
        }
    }
}

#Preview("Running") {
    TerminalPaneView(isFocused: true)
        .frame(width: 360, height: 240)
        .preferredColorScheme(.dark)
}

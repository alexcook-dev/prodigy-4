import SwiftUI

/// Bottom-right terminal panel: SwiftTerm PTY shell (T7) + keyboard passthrough (T10).
///
/// Failure state (PLAN.md Constraints / wf-3 #5): exited shell shows a visible
/// "process ended" bar with Restart — never a frozen pane.
struct TerminalPaneView: View {
    var isFocused: Bool = false
    var onPaneShortcut: ((WorkspacePane) -> Void)?

    @StateObject private var session = TerminalSessionController()

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            terminalBody
            if session.showsProcessEndedBar {
                processEndedBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.terminalBackground)
        .onAppear {
            // Clicking the pane focuses the terminal for typing.
        }
    }

    // MARK: - Header

    private var panelHeader: some View {
        // sc1-style tab strip: Terminal is the active tab; Setup/Run are chrome placeholders.
        HStack(spacing: 0) {
            terminalTab(title: "Setup", selected: false)
            terminalTab(title: "Run", selected: false)
            terminalTab(title: "Terminal", selected: true)

            Button {
                // Reserved for multi-terminal sessions later.
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New terminal (coming soon)")

            Spacer(minLength: 8)

            Text(session.headerTitle)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
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

    private func terminalTab(title: String, selected: Bool) -> some View {
        Text(title)
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.clear)
            .overlay(alignment: .bottom) {
                if selected {
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(height: 2)
                }
            }
    }

    // MARK: - Terminal body

    private var terminalBody: some View {
        TerminalViewRepresentable(
            session: session,
            isFocused: isFocused,
            onPaneShortcut: onPaneShortcut
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Dim the buffer when the shell has exited so the dead state is obvious
        // even before the eye hits the process-ended bar (wf-3 #5).
        .opacity(session.isProcessRunning ? 1.0 : 0.55)
        .allowsHitTesting(session.isProcessRunning)
        .accessibilityLabel("Terminal")
        .accessibilityValue(session.isProcessRunning ? "Shell running" : session.processEndedMessage)
    }

    // MARK: - Process ended (T7)

    private var processEndedBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)

            Text(session.processEndedMessage)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: 8)

            Button {
                session.requestRestart()
            } label: {
                Text("Restart shell ⏎")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glass)
            // No global Return shortcut — that would steal Enter from chat/composer
            // while the process-ended bar is visible. Click (or later pane-local
            // binding) restarts; label keeps the ⏎ affordance from the wireframe.
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

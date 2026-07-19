import SwiftUI

/// Bottom-right terminal placeholder.
/// Real SwiftTerm + pty + process-ended state is T7; keyboard passthrough is T10.
struct TerminalPaneView: View {
    /// Active Project's working folder for the prompt display.
    var projectFolderPath: String? = nil
    var isFocused: Bool = false

    private var promptPath: String {
        guard let projectFolderPath else { return "~" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if projectFolderPath.hasPrefix(home) {
            return "~" + projectFolderPath.dropFirst(home.count)
        }
        return projectFolderPath
    }

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            terminalBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.terminalBackground)
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(Theme.focusRing, lineWidth: 2)
            }
        }
    }

    private var panelHeader: some View {
        HStack {
            Text("Terminal — zsh")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .textCase(.uppercase)
                .tracking(0.6)

            Spacer()

            Image(systemName: "chevron.up")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.terminalBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.borderHairline)
                .frame(height: 1)
        }
    }

    private var terminalBody: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("\(promptPath) $")
                    .foregroundStyle(Theme.terminalPrompt)
                Rectangle()
                    .fill(Theme.terminalText)
                    .frame(width: 7, height: 13)
                    .opacity(0.85)
            }

            Spacer(minLength: 8)

            Text("Terminal is a placeholder — SwiftTerm + pty land in T7.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

#Preview {
    TerminalPaneView()
        .frame(width: 320, height: 220)
        .preferredColorScheme(.dark)
}

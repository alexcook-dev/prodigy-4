import SwiftData
import SwiftUI

/// First-run / zero-Projects greeting (wf-2). Shown when no Projects exist yet.
/// "Create your first Project" opens the creation sheet; "quick chat" auto-creates
/// a real hidden Project (T11).
struct FirstRunView: View {
    var onCreateProject: () -> Void
    var onQuickChat: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "circle.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.textSecondary)
                .opacity(0.9)
                .accessibilityHidden(true)

            Text(greeting)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .tracking(-0.2)

            Text(
                "One place for the day's work: chat in the middle, your files and terminal on the right, projects on the left. Start by making a project — or just say something."
            )
            .font(.system(size: 14))
            .foregroundStyle(Theme.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
            .lineSpacing(3)

            Button(action: onCreateProject) {
                Text("Create your first Project")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textOnAccent)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.accent)
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 6)

            Button(action: onQuickChat) {
                Text("or start a quick chat ⏎")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accentText)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [])

            HStack(alignment: .top, spacing: 12) {
                tipCard(
                    title: "Chat is the center",
                    body: "Everything routes through the conversation. ⌘2 gets you back here."
                )
                tipCard(
                    title: "Projects remember",
                    body: "Each project keeps its own chats and working folder."
                )
                tipCard(
                    title: "Agents are personas",
                    body: "Saved system prompts you can call from any project."
                )
            }
            .padding(.top, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background(Theme.centerBackground)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private func tipCard(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(body)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 170, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.elevatedSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.borderStructural, lineWidth: 1)
                )
        )
    }
}

#Preview {
    FirstRunView(onCreateProject: {}, onQuickChat: {})
        .frame(width: 700, height: 520)
        .preferredColorScheme(.dark)
}

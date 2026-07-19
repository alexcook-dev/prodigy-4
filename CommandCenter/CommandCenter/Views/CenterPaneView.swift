import SwiftUI

/// Center pane: chat thread (default) or file preview tabs.
/// Chat streaming, provider wiring, and real preview are later waves — shell only.
struct CenterPaneView: View {
    var isFocused: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            chatPlaceholder
            composerPlaceholder
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.centerBackground)
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(Theme.focusRing, lineWidth: 2)
            }
        }
    }

    // MARK: - Tabs

    private var tabBar: some View {
        HStack(spacing: 4) {
            CenterTab(title: "Chat — Kickoff", isActive: true, showsClose: false)
            CenterTab(title: "hero-v3.tsx", isActive: false, showsClose: true)
            Button {
                // T5/T11: "+" opens file-preview tabs only, never a second chat thread.
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 7,
                            bottomLeadingRadius: 0,
                            bottomTrailingRadius: 0,
                            topTrailingRadius: 7,
                            style: .continuous
                        )
                        .fill(Theme.appBackground)
                    )
            }
            .buttonStyle(.plain)
            .help("Open file preview")

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 0)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.borderHairline)
                .frame(height: 1)
        }
    }

    // MARK: - Chat body (placeholder)

    private var chatPlaceholder: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Spacer(minLength: 40)
                    Text("Summarize where we landed on the hero section yesterday.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(
                            UnevenRoundedRectangle(
                                topLeadingRadius: 12,
                                bottomLeadingRadius: 12,
                                bottomTrailingRadius: 4,
                                topTrailingRadius: 12,
                                style: .continuous
                            )
                            .fill(Theme.userMessageFill)
                            .overlay(
                                UnevenRoundedRectangle(
                                    topLeadingRadius: 12,
                                    bottomLeadingRadius: 12,
                                    bottomTrailingRadius: 4,
                                    topTrailingRadius: 12,
                                    style: .continuous
                                )
                                .strokeBorder(Theme.userMessageBorder, lineWidth: 1)
                            )
                        )
                        .frame(maxWidth: 480, alignment: .trailing)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Claude · Sonnet · High effort")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)

                    Text(
                        "Yesterday you settled three things: the headline drops the subhead entirely, "
                            + "the CTA moves above the fold, and the hero image swaps to the darker variant. "
                            + "The open question was whether the announcement banner stays."
                    )
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .lineSpacing(3)
                    .frame(maxWidth: 720, alignment: .leading)
                }

                HStack {
                    Spacer(minLength: 40)
                    Text("Draft a Slack message to Dana asking for that data.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(
                            UnevenRoundedRectangle(
                                topLeadingRadius: 12,
                                bottomLeadingRadius: 12,
                                bottomTrailingRadius: 4,
                                topTrailingRadius: 12,
                                style: .continuous
                            )
                            .fill(Theme.userMessageFill)
                            .overlay(
                                UnevenRoundedRectangle(
                                    topLeadingRadius: 12,
                                    bottomLeadingRadius: 12,
                                    bottomTrailingRadius: 4,
                                    topTrailingRadius: 12,
                                    style: .continuous
                                )
                                .strokeBorder(Theme.userMessageBorder, lineWidth: 1)
                            )
                        )
                        .frame(maxWidth: 480, alignment: .trailing)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Claude · Sonnet · High effort")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)

                    HStack(spacing: 10) {
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 8, height: 8)
                            .opacity(0.85)
                            .accessibilityLabel("Streaming")

                        Text("Streaming…")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)

                        Text("Stop")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textRow)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 2)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(Theme.controlBorder, lineWidth: 1)
                            )
                    }
                }

                Text("Chat UI is a placeholder — provider + streaming land in later waves.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 8)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Composer (placeholder; no usage meter in V1)

    private var composerPlaceholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Message Website Redesign…")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("⏎ send · ⇧⏎ newline")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.elevatedSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Theme.borderStructural, lineWidth: 1)
                    )
            )

            HStack(spacing: 8) {
                composerPill("Claude · Sonnet")
                composerPill("Effort: High")
                Spacer()
                // Usage meter intentionally omitted in V1 (PLAN.md NOT in Scope / Pass 7 #18).
            }
            .font(.system(size: 11))
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.borderHairline)
                .frame(height: 1)
        }
    }

    private func composerPill(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Theme.chipBackground)
                    .overlay(
                        Capsule()
                            .strokeBorder(Theme.borderStructural, lineWidth: 1)
                    )
            )
    }
}

private struct CenterTab: View {
    let title: String
    let isActive: Bool
    let showsClose: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
            if showsClose {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 7,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 7,
                style: .continuous
            )
            .fill(isActive ? Theme.centerBackground : Theme.appBackground)
            .overlay(alignment: .bottom) {
                if isActive {
                    Rectangle()
                        .fill(Theme.centerBackground)
                        .frame(height: 2)
                        .offset(y: 1)
                }
            }
            .overlay {
                if isActive {
                    UnevenRoundedRectangle(
                        topLeadingRadius: 7,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 7,
                        style: .continuous
                    )
                    .strokeBorder(Theme.borderHairline, lineWidth: 1)
                }
            }
        )
    }
}

#Preview {
    CenterPaneView()
        .frame(width: 640, height: 700)
        .preferredColorScheme(.dark)
}

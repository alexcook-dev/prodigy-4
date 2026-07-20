import SwiftUI

/// Settings surface — native Form layout (HIG).
/// Appearance + Claude Max/Pro subscription status (Claude Code CLI auth).
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppStorageKey.appearance) private var appearanceRaw = AppAppearance.system.rawValue
    @State private var auth = ClaudeAuthService.shared
    @State private var isRefreshing = false

    private var appearance: Binding<AppAppearance> {
        Binding(
            get: { AppAppearance(rawValue: appearanceRaw) ?? .system },
            set: { appearanceRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                appearanceSection
                claudeSubscriptionSection
            }
            .formStyle(.grouped)
            .font(AppTypography.body)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(AppTypography.action)
                }
            }
            .task {
                await refreshAuth()
            }
        }
        .frame(minWidth: 440, minHeight: 420)
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section {
            Picker("Appearance", selection: appearance) {
                ForEach(AppAppearance.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        } header: {
            Text("Appearance")
        } footer: {
            Text("System follows macOS. Light matches the sc2 light shell; Dark matches the sc1 dark shell.")
                .font(AppTypography.caption)
        }
    }

    // MARK: - Claude Max / Pro subscription

    private var claudeSubscriptionSection: some View {
        Section {
            statusRow

            if auth.snapshot.hasAPIKeyInEnvironment {
                apiKeyWarningRow
            }

            HStack(spacing: 12) {
                Button {
                    Task { await refreshAuth() }
                } label: {
                    if isRefreshing || auth.snapshot.state == .checking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Refresh status")
                    }
                }
                .disabled(isRefreshing || auth.snapshot.state == .checking)

                Spacer()

                switch auth.snapshot.state {
                case .loggedIn:
                    Button("Re-authenticate…") {
                        auth.openClaudeAILogin()
                    }
                case .loggedOut, .cliMissing, .probeFailed, .idle, .checking:
                    Button("Sign in with Claude Max…") {
                        auth.openClaudeAILogin()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        } header: {
            Text("Claude subscription")
        } footer: {
            Text(footerCopy)
                .font(AppTypography.caption)
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(alignment: .top, spacing: 12) {
            statusDot
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(statusTitle)
                    .font(AppTypography.body.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)

                if let detail = statusDetail {
                    Text(detail)
                        .font(AppTypography.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                }

                if case .loggedIn(let account) = auth.snapshot.state, account.isMax {
                    Text("Max plan — higher usage limits on the same Claude Code login.")
                        .font(AppTypography.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(statusTitle). \(statusDetail ?? "")")
    }

    private var apiKeyWarningRow: some View {
        Label {
            Text("ANTHROPIC_API_KEY is set in the environment. Prodigy strips it for chat so your Max/Pro subscription is used instead of API billing.")
                .font(AppTypography.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 9, height: 9)
            .accessibilityHidden(true)
    }

    private var statusColor: Color {
        switch auth.snapshot.state {
        case .loggedIn: return Theme.statusDone
        case .checking, .idle: return Theme.textTertiary
        case .loggedOut, .cliMissing, .probeFailed: return Theme.statusBusy
        }
    }

    private var statusTitle: String {
        switch auth.snapshot.state {
        case .idle, .checking:
            return "Checking Claude Code…"
        case .cliMissing:
            return "Claude Code CLI not found"
        case .loggedOut:
            return "Not signed in"
        case .loggedIn(let account):
            return account.planDisplayName
        case .probeFailed:
            return "Could not read login status"
        }
    }

    private var statusDetail: String? {
        switch auth.snapshot.state {
        case .idle, .checking:
            return nil
        case .cliMissing:
            return "Install Claude Code, then reopen Settings. Prodigy uses the same login as the CLI."
        case .loggedOut:
            return "Sign in with your Claude.ai account (Max or Pro) to chat without an API key."
        case .loggedIn(let account):
            var parts: [String] = []
            if let email = account.email, !email.isEmpty {
                parts.append(email)
            }
            if let method = account.authMethod, !method.isEmpty {
                parts.append("via \(method)")
            }
            if let path = auth.snapshot.executablePath {
                parts.append(path)
            }
            return parts.isEmpty ? "Signed in via Claude Code" : parts.joined(separator: " · ")
        case .probeFailed(let message):
            return message
        }
    }

    private var footerCopy: String {
        "Prodigy chats through the installed Claude Code CLI using your Claude Max or Pro subscription — not Anthropic API keys. Sign-in opens Terminal and runs claude auth login --claudeai."
    }

    private func refreshAuth() async {
        isRefreshing = true
        await auth.refresh()
        isRefreshing = false
    }
}

#Preview {
    SettingsView()
}

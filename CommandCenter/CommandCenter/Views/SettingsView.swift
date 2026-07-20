import SwiftUI

/// Settings — appearance + Claude + Grok authentication + usage.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppStorageKey.appearance) private var appearanceRaw = AppAppearance.system.rawValue
    @AppStorage(AppStorageKey.contentZoom) private var zoomLevel = ContentZoom.default
    @State private var claudeAuth = ClaudeAuthService.shared
    @State private var grokAuth = GrokAuthService.shared
    @ObservedObject private var usageMeter = UsageMeterService.shared
    @ObservedObject private var appUpdates = AppUpdateService.shared
    @State private var isRefreshingClaude = false
    @State private var isRefreshingGrok = false

    private var appearance: Binding<AppAppearance> {
        Binding(
            get: { AppAppearance(rawValue: appearanceRaw) ?? .system },
            set: { appearanceRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                updatesSection
                appearanceSection
                zoomSection
                usageSection
                claudeSubscriptionSection
                grokSection
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
                await refreshAll()
                await usageMeter.syncClaudeUsageFromCLI()
            }
        }
        .frame(minWidth: 460, minHeight: 560)
    }

    // MARK: - Updates

    private var updatesSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Installed version")
                        .font(AppTypography.body)
                    Text(appUpdates.currentVersion)
                        .font(AppTypography.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                updateStatusLabel
            }

            HStack {
                Button {
                    Task { await appUpdates.checkForUpdates(userInitiated: true) }
                } label: {
                    if case .checking = appUpdates.phase {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Check for Updates")
                    }
                }
                .disabled({
                    if case .checking = appUpdates.phase { return true }
                    if case .downloading = appUpdates.phase { return true }
                    if case .installing = appUpdates.phase { return true }
                    return false
                }())

                Spacer()

                if case .available = appUpdates.phase {
                    Button("Install Update") {
                        Task { await appUpdates.installAvailableUpdate() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled({
                        if case .downloading = appUpdates.phase { return true }
                        if case .installing = appUpdates.phase { return true }
                        return false
                    }())
                }
            }

            if case .available(let u) = appUpdates.phase, !u.notes.isEmpty {
                Text(u.notes)
                    .font(AppTypography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Updates")
        } footer: {
            Text(updatesFooter)
                .font(AppTypography.caption)
        }
    }

    @ViewBuilder
    private var updateStatusLabel: some View {
        switch appUpdates.phase {
        case .idle:
            Text(appUpdates.isProductionBuild ? "Not checked yet" : "Dev build")
                .font(AppTypography.caption)
                .foregroundStyle(Theme.textTertiary)
        case .checking:
            Text("Checking…")
                .font(AppTypography.caption)
                .foregroundStyle(Theme.textSecondary)
        case .upToDate:
            Text("Up to date")
                .font(AppTypography.caption)
                .foregroundStyle(Theme.statusDone)
        case .available(let u):
            Text("\(u.version) available")
                .font(AppTypography.caption)
                .foregroundStyle(Theme.accent)
        case .downloading(let fraction):
            if let fraction {
                Text("Downloading \(Int(fraction * 100))%")
                    .font(AppTypography.caption)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text("Downloading…")
                    .font(AppTypography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .installing:
            Text("Installing…")
                .font(AppTypography.caption)
                .foregroundStyle(Theme.textSecondary)
        case .failed(let message):
            Text(message)
                .font(AppTypography.caption)
                .foregroundStyle(Theme.errorText)
                .lineLimit(3)
                .frame(maxWidth: 220, alignment: .trailing)
        }
    }

    private var updatesFooter: String {
        if appUpdates.isProductionBuild {
            return "Checks public GitHub Releases for a newer Prodigy-*.dmg. No GitHub login required. Install places the DMG and Prodigy.app in /Applications (or ~/Applications)."
        }
        return "You’re on Prodigy Dev (Xcode). Auto-update is for the production app only; you can still Check manually."
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
            Text("System follows macOS. Light and Dark lock the app independently.")
                .font(AppTypography.caption)
        }
    }

    // MARK: - Zoom

    private var zoomSection: some View {
        Section {
            HStack {
                Text("Zoom")
                Spacer()
                Text(ContentZoom.percentLabel(zoomLevel))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
            }
            HStack(spacing: 12) {
                Button("−") {
                    zoomLevel = ContentZoom.zoomOut(zoomLevel)
                }
                .disabled(zoomLevel <= ContentZoom.minimum + 0.001)
                .help("Zoom Out (⌘-)")

                Slider(
                    value: Binding(
                        get: { zoomLevel },
                        set: { zoomLevel = ContentZoom.clamped($0) }
                    ),
                    in: ContentZoom.minimum...ContentZoom.maximum,
                    step: ContentZoom.step
                )

                Button("+") {
                    zoomLevel = ContentZoom.zoomIn(zoomLevel)
                }
                .disabled(zoomLevel >= ContentZoom.maximum - 0.001)
                .help("Zoom In (⌘=)")

                Button("100%") {
                    zoomLevel = ContentZoom.default
                }
                .disabled(abs(zoomLevel - ContentZoom.default) < 0.001)
                .help("Actual Size (⌘0)")
            }
        } header: {
            Text("Zoom")
        } footer: {
            Text("⌘= / ⌘+ zoom in · ⌘- zoom out · ⌘0 actual size. Saved for next launch.")
                .font(AppTypography.caption)
        }
    }

    // MARK: - Usage

    private var usageSection: some View {
        UsageSettingsSection(meter: usageMeter)
    }

    // MARK: - Claude

    private var claudeSubscriptionSection: some View {
        Section {
            authStatusRow(
                title: claudeStatusTitle,
                detail: claudeStatusDetail,
                color: claudeStatusColor,
                isMax: {
                    if case .loggedIn(let a) = claudeAuth.snapshot.state { return a.isMax }
                    return false
                }()
            )

            if claudeAuth.snapshot.hasAPIKeyInEnvironment {
                Label {
                    Text("ANTHROPIC_API_KEY is set. Prodigy strips it for Claude turns so Max/Pro OAuth is used.")
                        .font(AppTypography.caption)
                        .foregroundStyle(Theme.textSecondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }

            HStack {
                Button {
                    Task { await refreshClaude() }
                } label: {
                    if isRefreshingClaude { ProgressView().controlSize(.small) }
                    else { Text("Refresh") }
                }
                .disabled(isRefreshingClaude)

                Spacer()

                if claudeAuth.snapshot.isLoggedIn {
                    Button("Re-authenticate…") { claudeAuth.openClaudeAILogin() }
                } else {
                    Button("Sign in with Claude…") { claudeAuth.openClaudeAILogin() }
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        } header: {
            Text("Claude")
        } footer: {
            Text("Claude Code CLI OAuth (`claude auth login --claudeai`). Used for Sonnet, Opus, and Haiku in the model picker.")
                .font(AppTypography.caption)
        }
    }

    // MARK: - Grok

    private var grokSection: some View {
        Section {
            authStatusRow(
                title: grokStatusTitle,
                detail: grokStatusDetail,
                color: grokStatusColor,
                isMax: false
            )

            if grokAuth.snapshot.hasAPIKeyInEnvironment {
                Label {
                    Text("XAI_API_KEY is set. Grok CLI prefers OAuth session when logged in; API key is a fallback.")
                        .font(AppTypography.caption)
                        .foregroundStyle(Theme.textSecondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }

            HStack {
                Button {
                    Task { await refreshGrok() }
                } label: {
                    if isRefreshingGrok { ProgressView().controlSize(.small) }
                    else { Text("Refresh") }
                }
                .disabled(isRefreshingGrok)

                Spacer()

                if grokAuth.snapshot.isLoggedIn {
                    Button("Log out…") { grokAuth.openLogout() }
                    Button("Re-authenticate…") { grokAuth.openLogin() }
                } else {
                    Button("Sign in with Grok…") { grokAuth.openLogin() }
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        } header: {
            Text("Grok")
        } footer: {
            Text("Grok CLI OAuth (`grok login`). Select Grok 4.5 in the chat model picker once signed in. CLI lives at ~/.grok/bin/grok.")
                .font(AppTypography.caption)
        }
    }

    // MARK: - Shared status row

    private func authStatusRow(
        title: String,
        detail: String?,
        color: Color,
        isMax: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(AppTypography.body.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                if let detail {
                    Text(detail)
                        .font(AppTypography.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                }
                if isMax {
                    Text("Max plan — higher Claude Code usage limits.")
                        .font(AppTypography.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
    }

    // MARK: - Claude copy

    private var claudeStatusTitle: String {
        switch claudeAuth.snapshot.state {
        case .idle, .checking: return "Checking Claude Code…"
        case .cliMissing: return "Claude Code CLI not found"
        case .loggedOut: return "Not signed in"
        case .loggedIn(let account): return account.planDisplayName
        case .probeFailed: return "Could not read Claude login"
        }
    }

    private var claudeStatusDetail: String? {
        switch claudeAuth.snapshot.state {
        case .idle, .checking: return nil
        case .cliMissing:
            return "Install Claude Code, then refresh."
        case .loggedOut:
            return "Sign in with your Claude.ai Max or Pro account."
        case .loggedIn(let account):
            var parts: [String] = []
            if let email = account.email, !email.isEmpty { parts.append(email) }
            if let method = account.authMethod { parts.append("via \(method)") }
            if let path = claudeAuth.snapshot.executablePath { parts.append(path) }
            return parts.isEmpty ? "Signed in" : parts.joined(separator: " · ")
        case .probeFailed(let message): return message
        }
    }

    private var claudeStatusColor: Color {
        switch claudeAuth.snapshot.state {
        case .loggedIn: return Theme.statusDone
        case .checking, .idle: return Theme.textTertiary
        case .loggedOut, .cliMissing, .probeFailed: return Theme.statusBusy
        }
    }

    // MARK: - Grok copy

    private var grokStatusTitle: String {
        switch grokAuth.snapshot.state {
        case .idle, .checking: return "Checking Grok…"
        case .cliMissing: return "Grok CLI not found"
        case .loggedOut: return "Not signed in"
        case .loggedIn: return "Grok signed in"
        case .probeFailed: return "Could not read Grok login"
        }
    }

    private var grokStatusDetail: String? {
        switch grokAuth.snapshot.state {
        case .idle, .checking: return nil
        case .cliMissing:
            return "Install grok (CLI at ~/.grok/bin/grok), then refresh."
        case .loggedOut:
            return "Sign in with grok.com (SpaceXAI OAuth) to use Grok in chat."
        case .loggedIn(let email, let mode):
            var parts: [String] = []
            if let email, !email.isEmpty { parts.append(email) }
            if let mode, !mode.isEmpty { parts.append("via \(mode)") }
            if let path = grokAuth.snapshot.executablePath { parts.append(path) }
            return parts.isEmpty ? "Signed in" : parts.joined(separator: " · ")
        case .probeFailed(let message): return message
        }
    }

    private var grokStatusColor: Color {
        switch grokAuth.snapshot.state {
        case .loggedIn: return Theme.statusDone
        case .checking, .idle: return Theme.textTertiary
        case .loggedOut, .cliMissing, .probeFailed: return Theme.statusBusy
        }
    }

    // MARK: - Refresh

    private func refreshAll() async {
        async let c: Void = refreshClaude()
        async let g: Void = refreshGrok()
        _ = await (c, g)
    }

    private func refreshClaude() async {
        isRefreshingClaude = true
        await claudeAuth.refresh()
        isRefreshingClaude = false
    }

    private func refreshGrok() async {
        isRefreshingGrok = true
        await grokAuth.refresh()
        isRefreshingGrok = false
    }
}

#Preview {
    SettingsView()
}

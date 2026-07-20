import AppKit
import SwiftUI

/// Settings — appearance, access, skills, Claude + Grok authentication + usage.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppStorageKey.appearance) private var appearanceRaw = AppAppearance.system.rawValue
    @AppStorage(AppStorageKey.contentZoom) private var zoomLevel = ContentZoom.default
    @AppStorage(AppStorageKey.fullMacAccess) private var fullMacAccess = false
    @State private var claudeAuth = ClaudeAuthService.shared
    @State private var grokAuth = GrokAuthService.shared
    @ObservedObject private var usageMeter = UsageMeterService.shared
    @ObservedObject private var appUpdates = AppUpdateService.shared
    @ObservedObject private var skills = ProdigySkillsService.shared
    @ObservedObject private var access = ProdigyAccessSettings.shared
    @State private var isRefreshingClaude = false
    @State private var isRefreshingGrok = false
    @State private var showNewSkillSheet = false
    @State private var editingSkill: ProdigySkill?
    @State private var skillError: String?

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
                accessSection
                skillsSection
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
                skills.reload()
                await refreshAll()
                await usageMeter.syncClaudeUsageFromCLI()
            }
            .sheet(isPresented: $showNewSkillSheet) {
                SkillEditorSheet(mode: .create) { name, description, body in
                    do {
                        _ = try skills.addSkill(name: name, description: description, body: body)
                        showNewSkillSheet = false
                        skillError = nil
                    } catch {
                        skillError = error.localizedDescription
                    }
                } onCancel: {
                    showNewSkillSheet = false
                }
            }
            .sheet(item: $editingSkill) { skill in
                SkillEditorSheet(mode: .edit(skill)) { name, description, body in
                    var updated = skill
                    updated.name = name
                    updated.description = description
                    updated.body = body
                    do {
                        try skills.updateSkill(updated)
                        editingSkill = nil
                        skillError = nil
                    } catch {
                        skillError = error.localizedDescription
                    }
                } onCancel: {
                    editingSkill = nil
                }
            }
        }
        .frame(minWidth: 480, minHeight: 620)
    }

    // MARK: - Full Mac access

    private var accessSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { fullMacAccess },
                set: { newValue in
                    fullMacAccess = newValue
                    access.setFullMacAccess(newValue)
                    // Rebuild CLI sessions so tools/permission flags take effect.
                    RoutingModelProvider.shared.teardownAll()
                }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Full Mac access")
                        .font(AppTypography.body.weight(.medium))
                    Text("Unrestricted tools — terminal, files, network (OpenClaw-style). Applies to Claude and Grok.")
                        .font(AppTypography.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Theme.accent)
        } header: {
            Text("Access")
        } footer: {
            Text(
                fullMacAccess
                    ? "ON: models can run shell commands, edit files, and use skills across your Mac. Permission prompts are auto-approved. Destructive actions still deserve care."
                    : "OFF (default): chat-only mode with tools disabled — safer for everyday conversation."
            )
            .font(AppTypography.caption)
        }
    }

    // MARK: - Skills

    private var skillsSection: some View {
        Section {
            if skills.skills.isEmpty {
                Text("No skills yet. Add one to share procedures across Claude and Grok.")
                    .font(AppTypography.caption)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(skills.skills) { skill in
                    HStack(alignment: .top, spacing: 10) {
                        Toggle(isOn: Binding(
                            get: { skill.enabled },
                            set: { enabled in
                                try? skills.setEnabled(slug: skill.slug, enabled: enabled)
                            }
                        )) {
                            EmptyView()
                        }
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .help(skill.enabled ? "Disable skill" : "Enable skill")

                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.name)
                                .font(AppTypography.body.weight(.medium))
                            Text("/\(skill.slug)")
                                .font(AppTypography.caption)
                                .foregroundStyle(Theme.textTertiary)
                            if !skill.description.isEmpty {
                                Text(skill.description)
                                    .font(AppTypography.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                        Button("Edit") { editingSkill = skill }
                            .buttonStyle(.borderless)
                        Button(role: .destructive) {
                            try? skills.deleteSkill(slug: skill.slug)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete skill")
                    }
                }
            }

            HStack {
                Button {
                    showNewSkillSheet = true
                } label: {
                    Label("Add Skill", systemImage: "plus")
                }
                Spacer()
                Button("Import…") {
                    importSkill()
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.open(skills.skillsRoot)
                }
            }

            if let skillError {
                Text(skillError)
                    .font(AppTypography.caption)
                    .foregroundStyle(Theme.errorText)
            }
            if let last = skills.lastError {
                Text(last)
                    .font(AppTypography.caption)
                    .foregroundStyle(Theme.errorText)
            }
        } header: {
            Text("Skills")
        } footer: {
            Text("Skills live in ~/.prodigy/skills and sync to ~/.claude/skills and ~/.grok/skills so every model sees the same set. Enabled skills are also injected into the chat system prompt.")
                .font(AppTypography.caption)
        }
    }

    private func importSkill() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a skill folder (with SKILL.md) or a SKILL.md file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try skills.importFromURL(url)
            skillError = nil
        } catch {
            skillError = error.localizedDescription
        }
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
            return "Checks private GitHub Releases for a newer Prodigy-*.dmg. Uses `gh auth token` (run `gh auth login` once). Install places the DMG and app in /Applications."
        }
        return "You’re on Prodigy Dev (Xcode). Auto-update toast is production-only; Check for Updates still works here."
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

// MARK: - Skill editor

private enum SkillEditorMode {
    case create
    case edit(ProdigySkill)
}

private struct SkillEditorSheet: View {
    let mode: SkillEditorMode
    var onSave: (_ name: String, _ description: String, _ body: String) -> Void
    var onCancel: () -> Void

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var bodyText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(Font.headline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)

            field(label: "Name", placeholder: "e.g. Weekly retro") {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
            }

            field(label: "Description", placeholder: "When should this skill run?") {
                TextField("Description", text: $description, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...4)
            }

            field(label: "Instructions (SKILL.md body)", placeholder: "Step-by-step…") {
                TextEditor(text: $bodyText)
                    .font(Font.system(.body, design: .monospaced))
                    .frame(minHeight: 160, maxHeight: 240)
                    .scrollContentBackground(.hidden)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                Button("Save") {
                    onSave(name, description, bodyText)
                }
                .buttonStyle(.plain)
                .font(Font.callout.weight(.medium))
                .foregroundStyle(Theme.textOnAccent)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.accent)
                )
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(Theme.appBackground)
        .onAppear {
            switch mode {
            case .create:
                name = ""
                description = ""
                bodyText = "# Instructions\n\nDescribe what this skill should do.\n"
            case .edit(let skill):
                name = skill.name
                description = skill.description
                bodyText = skill.body
            }
        }
    }

    private var title: String {
        switch mode {
        case .create: return "New Skill"
        case .edit: return "Edit Skill"
        }
    }

    private func field<Content: View>(
        label: String,
        placeholder: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(Font.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .textCase(.uppercase)
                .tracking(0.6)
            content()
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.elevatedSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Theme.borderStructural, lineWidth: 1)
                        )
                )
                .help(placeholder)
        }
    }
}

#Preview {
    SettingsView()
}

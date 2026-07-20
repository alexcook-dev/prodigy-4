import SwiftUI

/// Compact usage gauge for the composer — shows **provider-reported** windows
/// (Claude session / week / 5-hour) with reset times when available.
struct UsageGaugePill: View {
    let model: ChatModelOption
    @ObservedObject var meter: UsageMeterService

    var body: some View {
        let fill = meter.primaryGaugeFill(for: model)
        let window = meter.primaryWindow(for: model)

        HStack(spacing: 8) {
            UsageRing(progress: fill, tint: ringColor(for: fill, hasWindow: window != nil))
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(meter.primaryGaugeLabel(for: model))
                    .font(Font.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Text(meter.primaryGaugeSubtitle(for: model))
                    .font(Font.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Theme.chipBackground)
        )
        .help(helpText(window: window))
        .task(id: model.id) {
            if model.family == .claude {
                await meter.syncClaudeUsageFromCLI()
            }
        }
    }

    private func helpText(window: ProviderQuotaWindow?) -> String {
        var lines: [String] = ["\(model.pillLabel) — provider usage"]
        if let window {
            lines.append("\(window.label): \(window.percentUsed)% used")
            if let reset = window.resetsDescription {
                lines.append(reset.capitalized)
            }
            if let status = window.status {
                lines.append("Status: \(status)")
            }
            lines.append("Source: \(window.source == "cli_usage" ? "Claude /usage" : "rate_limit_event")")
        } else if model.family == .claude {
            lines.append("No live Claude window yet. Send a turn or open Settings → Usage → Refresh.")
        } else {
            lines.append("Grok has no public rate-window API in the CLI; only local Prodigy turns are counted.")
        }
        let today = meter.todayUsage(for: model)
        let week = meter.weekUsage(for: model)
        lines.append("Prodigy activity today: \(today.turns) turns, \(meter.formatTokens(today.totalTokens)) tok")
        lines.append("Prodigy activity week: \(week.turns) turns, \(meter.formatTokens(week.totalTokens)) tok")
        return lines.joined(separator: "\n")
    }

    private func ringColor(for fill: Double, hasWindow: Bool) -> Color {
        guard hasWindow || fill > 0 else { return Theme.textTertiary }
        if fill >= 0.9 { return Theme.statusBusy }
        if fill >= 0.7 { return Color.orange }
        return Theme.accent
    }
}

/// Settings: authoritative provider windows + local activity per model.
struct UsageSettingsSection: View {
    @ObservedObject var meter: UsageMeterService

    var body: some View {
        Section {
            // Claude subscription windows (authoritative)
            if meter.isSyncing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Refreshing Claude usage…")
                        .font(AppTypography.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            if let err = meter.lastSyncError, meter.claudeWindowsSorted.isEmpty {
                Text(err)
                    .font(AppTypography.caption)
                    .foregroundStyle(Theme.errorText)
            }

            if meter.claudeWindowsSorted.isEmpty && !meter.isSyncing {
                Text("No Claude rate windows loaded yet. Refresh to pull session / weekly limits from Claude Code.")
                    .font(AppTypography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            ForEach(meter.claudeWindowsSorted) { window in
                windowRow(window)
            }

            HStack {
                Button {
                    Task { await meter.syncClaudeUsageFromCLI() }
                } label: {
                    if meter.isSyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Refresh Claude usage")
                    }
                }
                .disabled(meter.isSyncing)

                Spacer()

                if let at = meter.lastSyncAt {
                    Text("Updated \(at.formatted(date: .omitted, time: .shortened))")
                        .font(AppTypography.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        } header: {
            Text("Claude subscription windows")
        } footer: {
            Text("These numbers match Claude Code /usage (session, week all models, week per model) and live rate_limit_event mid-turn. Resets use the times Claude reports.")
                .font(AppTypography.caption)
        }

        Section {
            ForEach(ChatModelOption.allCases) { model in
                modelActivityRow(model)
            }

            Button("Clear local Prodigy turn counters…", role: .destructive) {
                meter.clearLocalActivity()
            }
        } header: {
            Text("Prodigy activity (this app)")
        } footer: {
            Text("Local turns/tokens seen inside Prodigy only — not your full Claude Code or claude.ai usage across devices. Prefer the subscription windows above for accuracy.")
                .font(AppTypography.caption)
        }
    }

    private func windowRow(_ window: ProviderQuotaWindow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            UsageRing(
                progress: min(1, max(0, window.utilization)),
                tint: window.percentUsed >= 90 ? Theme.statusBusy : Theme.accent
            )
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(window.label)
                    .font(AppTypography.body.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(window.percentUsed)% used")
                    .font(AppTypography.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                if let reset = window.resetsDescription {
                    Text(reset)
                        .font(AppTypography.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
                if let status = window.status, !status.isEmpty {
                    Text(status)
                        .font(AppTypography.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
    }

    private func modelActivityRow(_ model: ChatModelOption) -> some View {
        let today = meter.todayUsage(for: model)
        let week = meter.weekUsage(for: model)
        let window = meter.primaryWindow(for: model)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.pillLabel)
                    .font(AppTypography.body.weight(.medium))
                Spacer()
                if let window {
                    Text("Quota \(window.percentUsed)%")
                        .font(AppTypography.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            if let window, let reset = window.resetsDescription {
                Text(reset)
                    .font(AppTypography.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            Text("Prodigy today: \(today.turns) turns · \(tokenLine(today))")
                .font(AppTypography.caption)
                .foregroundStyle(Theme.textSecondary)
            Text("Prodigy week: \(week.turns) turns · \(tokenLine(week))")
                .font(AppTypography.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 2)
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
    }

    private func tokenLine(_ u: ModelDayUsage) -> String {
        let t = meter.formatTokens(u.totalTokens)
        if u.hasReportedTokens { return "\(t) tok" }
        return u.estimatedTokens > 0 ? "~\(t) tok" : "—"
    }
}

// MARK: - Ring

struct UsageRing: View {
    let progress: Double
    var tint: Color = Theme.accent
    var lineWidth: CGFloat = 2.5

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.chipBackground, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .accessibilityLabel("Usage \(Int((progress * 100).rounded())) percent")
    }
}

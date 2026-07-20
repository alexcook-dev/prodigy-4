import Foundation
import SwiftUI

// MARK: - Local turn accounting (secondary)

/// Local Prodigy activity for a calendar day (not the provider quota itself).
struct ModelDayUsage: Codable, Equatable, Sendable {
    var turns: Int = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var estimatedTokens: Int = 0

    var totalTokens: Int {
        let reported = inputTokens + outputTokens
        return reported > 0 ? reported : estimatedTokens
    }

    var hasReportedTokens: Bool { inputTokens + outputTokens > 0 }

    mutating func add(
        turns: Int = 1,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        estimatedTokens: Int = 0
    ) {
        self.turns += turns
        self.inputTokens += inputTokens
        self.outputTokens += outputTokens
        self.estimatedTokens += estimatedTokens
    }
}

// MARK: - Provider quota windows (primary / accurate)

/// A real subscription rate window from Claude Code (`/usage` or `rate_limit_event`).
struct ProviderQuotaWindow: Codable, Equatable, Identifiable, Sendable {
    /// Stable id e.g. `claude.session`, `claude.week.all`, `claude.week.sonnet`, `claude.five_hour`
    var id: String
    var provider: String // "claude" | "grok"
    var label: String
    /// 0…1+ fraction used
    var utilization: Double
    var resetsAt: Date?
    var status: String?
    /// Optional model binding for model-specific week windows
    var modelRawValue: String?
    var source: String // "cli_usage" | "rate_limit_event"
    var updatedAt: Date

    var percentUsed: Int { Int((min(max(utilization, 0), 1) * 100).rounded()) }

    var isStale: Bool {
        // Treat windows as stale after 2 hours without refresh so UI doesn't lie.
        Date().timeIntervalSince(updatedAt) > 2 * 3600
    }

    var resetsDescription: String? {
        guard let resetsAt else { return nil }
        let now = Date()
        if resetsAt <= now { return "reset due" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let rel = formatter.localizedString(for: resetsAt, relativeTo: now)
        let abs = resetsAt.formatted(date: .omitted, time: .shortened)
        return "resets \(abs) (\(rel))"
    }
}

// MARK: - Store

private struct UsageStoreBlob: Codable {
    var days: [String: [String: ModelDayUsage]] = [:]
    var windows: [String: ProviderQuotaWindow] = [:]
    /// Legacy single window (migrated on load).
    var rateWindow: LegacyRateWindow?

    struct LegacyRateWindow: Codable {
        var utilization: Double
        var resetsAt: Date?
        var status: String?
        var updatedAt: Date
    }
}

// MARK: - Service

/// Usage meter grounded in **provider-reported** rate windows + resets.
///
/// Primary source (Claude Max/Pro):
/// - `claude -p "/usage"` → session %, week (all models), week (per model), reset times
/// - Stream `rate_limit_event` → live five_hour / other windows mid-turn
///
/// Secondary (local Prodigy activity): turns + tokens seen in this app only.
@MainActor
final class UsageMeterService: ObservableObject {
    static let shared = UsageMeterService()

    @Published private(set) var days: [String: [String: ModelDayUsage]] = [:]
    @Published private(set) var windows: [String: ProviderQuotaWindow] = [:]
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastSyncError: String?
    @Published private(set) var isSyncing = false

    private let defaultsKey = "prodigy.usage.meter.v2"
    private let calendar = Calendar.current
    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private init() {
        load()
    }

    // MARK: - Record local turns

    func recordTurn(
        model: ChatModelOption,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        inputChars: Int = 0,
        outputChars: Int = 0
    ) {
        let key = dayKey(for: Date())
        var snapshot = days
        var day = snapshot[key] ?? [:]
        var bucket = day[model.rawValue] ?? ModelDayUsage()
        let inTok = inputTokens ?? 0
        let outTok = outputTokens ?? 0
        let estimated = (inTok + outTok > 0) ? 0 : max(1, (inputChars + outputChars) / 4)
        bucket.add(
            turns: 1,
            inputTokens: inTok,
            outputTokens: outTok,
            estimatedTokens: estimated
        )
        day[model.rawValue] = bucket
        snapshot[key] = day
        days = snapshot
        pruneOldDays(keepingLast: 60)
        save()
    }

    // MARK: - Provider windows

    /// Apply a stream `rate_limit_event` (live mid-turn signal).
    func updateFromRateLimitEvent(
        utilization: Double?,
        resetsAt: Date?,
        status: String?,
        rateLimitType: String?
    ) {
        guard let utilization else { return }
        let typeKey = (rateLimitType ?? "session")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        let id = "claude.\(typeKey)"
        let label: String
        switch typeKey {
        case "five_hour", "5h", "fivehour":
            label = "Claude · 5-hour window"
        case "seven_day", "7d", "week", "weekly":
            label = "Claude · Weekly window"
        case "session":
            label = "Claude · Session"
        default:
            label = "Claude · \(rateLimitType ?? typeKey)"
        }
        upsertWindow(
            ProviderQuotaWindow(
                id: id,
                provider: "claude",
                label: label,
                utilization: min(max(utilization, 0), 1.5),
                resetsAt: resetsAt,
                status: status,
                modelRawValue: nil,
                source: "rate_limit_event",
                updatedAt: Date()
            )
        )
    }

    /// Replace Claude windows parsed from `/usage` text (authoritative snapshot).
    func applyClaudeUsageWindows(_ list: [ProviderQuotaWindow]) {
        var next = windows
        // Drop previous cli_usage Claude windows; keep live rate_limit_event ones
        // unless superseded by same id.
        for (key, win) in windows where win.provider == "claude" && win.source == "cli_usage" {
            next.removeValue(forKey: key)
        }
        for win in list {
            next[win.id] = win
        }
        windows = next
        lastSyncAt = Date()
        lastSyncError = nil
        save()
    }

    func markSyncFailed(_ message: String) {
        lastSyncError = message
    }

    func upsertWindow(_ window: ProviderQuotaWindow) {
        var next = windows
        next[window.id] = window
        windows = next
        save()
    }

    // MARK: - Queries for UI

    /// Sorted Claude provider windows for Settings.
    var claudeWindowsSorted: [ProviderQuotaWindow] {
        windows.values
            .filter { $0.provider == "claude" && !$0.isStale }
            .sorted { a, b in
                // Prefer model-specific week, then week all, then session, then others
                rank(a) < rank(b)
            }
    }

    private func rank(_ w: ProviderQuotaWindow) -> Int {
        if w.id.contains("week.") && w.modelRawValue != nil { return 0 }
        if w.id == "claude.week.all" { return 1 }
        if w.id == "claude.session" { return 2 }
        if w.id.contains("five_hour") { return 3 }
        return 4
    }

    /// Best window to show for the currently selected model.
    func primaryWindow(for model: ChatModelOption) -> ProviderQuotaWindow? {
        let fresh = windows.values.filter { !$0.isStale && $0.provider == "claude" }
        guard model.family == .claude else {
            // Grok: no subscription window API yet
            return nil
        }
        // 1) Model-specific week
        if let match = fresh.first(where: { $0.modelRawValue == model.rawValue }) {
            return match
        }
        // 2) Week all models
        if let all = fresh.first(where: { $0.id == "claude.week.all" }) {
            return all
        }
        // 3) five_hour from stream
        if let five = fresh.first(where: { $0.id.contains("five_hour") }) {
            return five
        }
        // 4) session
        if let session = fresh.first(where: { $0.id == "claude.session" }) {
            return session
        }
        return fresh.max(by: { $0.updatedAt < $1.updatedAt })
    }

    func primaryGaugeFill(for model: ChatModelOption) -> Double {
        if let w = primaryWindow(for: model) {
            return min(1, max(0, w.utilization))
        }
        // No provider data yet — don't invent a fake quota fill.
        return 0
    }

    func primaryGaugeLabel(for model: ChatModelOption) -> String {
        if let w = primaryWindow(for: model) {
            return "\(w.percentUsed)% used"
        }
        if model.family == .claude {
            return lastSyncError != nil ? "Usage unavailable" : "Syncing usage…"
        }
        let t = todayUsage(for: model)
        return t.turns == 0 ? "No Grok quota API" : "Today \(t.turns) turns"
    }

    func primaryGaugeSubtitle(for model: ChatModelOption) -> String {
        if let w = primaryWindow(for: model) {
            if let reset = w.resetsDescription {
                return "\(shortLabel(w)) · \(reset)"
            }
            return shortLabel(w)
        }
        let today = todayUsage(for: model)
        if today.turns > 0 {
            let tok = formatTokens(today.totalTokens)
            let prefix = today.hasReportedTokens ? tok : "~\(tok)"
            return "Prodigy today \(today.turns)·\(prefix)"
        }
        return model.family == .claude ? "Open Settings or send a Claude turn" : "Local turns only"
    }

    private func shortLabel(_ w: ProviderQuotaWindow) -> String {
        if w.id == "claude.session" { return "Session" }
        if w.id == "claude.week.all" { return "Week (all)" }
        if w.id.contains("five_hour") { return "5-hour" }
        if let m = w.modelRawValue, let opt = ChatModelOption(rawValue: m) {
            return "Week (\(opt.displayName))"
        }
        if w.id.hasPrefix("claude.week.") {
            let name = w.id.replacingOccurrences(of: "claude.week.", with: "")
            return "Week (\(name.capitalized))"
        }
        return w.label
    }

    func usage(for model: ChatModelOption, on day: Date = Date()) -> ModelDayUsage {
        days[dayKey(for: day)]?[model.rawValue] ?? ModelDayUsage()
    }

    func weekUsage(for model: ChatModelOption, ending day: Date = Date()) -> ModelDayUsage {
        var total = ModelDayUsage()
        for offset in 0..<7 {
            guard let d = calendar.date(byAdding: .day, value: -offset, to: day) else { continue }
            let u = usage(for: model, on: d)
            total.add(
                turns: u.turns,
                inputTokens: u.inputTokens,
                outputTokens: u.outputTokens,
                estimatedTokens: u.estimatedTokens
            )
        }
        return total
    }

    func todayUsage(for model: ChatModelOption) -> ModelDayUsage {
        usage(for: model, on: Date())
    }

    func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 10_000 { return String(format: "%.0fk", Double(n) / 1000) }
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }

    func clearLocalActivity() {
        days = [:]
        save()
    }

    func clearAll() {
        days = [:]
        windows = [:]
        lastSyncAt = nil
        lastSyncError = nil
        save()
    }

    // MARK: - Sync from Claude CLI `/usage`

    /// Fetch authoritative Claude Max/Pro windows via `claude -p "/usage"`.
    func syncClaudeUsageFromCLI() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            let text = try await ClaudeUsageProbe.fetchUsageText()
            let parsed = ClaudeUsageProbe.parseWindows(from: text)
            if parsed.isEmpty {
                markSyncFailed("Claude /usage returned no windows.")
            } else {
                applyClaudeUsageWindows(parsed)
            }
        } catch {
            markSyncFailed(error.localizedDescription)
        }
    }

    // MARK: - Persistence

    private func dayKey(for date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private func pruneOldDays(keepingLast n: Int) {
        let sorted = days.keys.sorted()
        guard sorted.count > n else { return }
        var snapshot = days
        for key in sorted.prefix(sorted.count - n) {
            snapshot.removeValue(forKey: key)
        }
        days = snapshot
    }

    private func load() {
        // Prefer v2; migrate v1 if needed.
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let blob = try? JSONDecoder().decode(UsageStoreBlob.self, from: data) {
            days = blob.days
            windows = blob.windows
            if windows.isEmpty, let legacy = blob.rateWindow {
                windows["claude.session"] = ProviderQuotaWindow(
                    id: "claude.session",
                    provider: "claude",
                    label: "Claude · Session",
                    utilization: legacy.utilization,
                    resetsAt: legacy.resetsAt,
                    status: legacy.status,
                    modelRawValue: nil,
                    source: "rate_limit_event",
                    updatedAt: legacy.updatedAt
                )
            }
            return
        }
        if let data = UserDefaults.standard.data(forKey: "prodigy.usage.meter.v1"),
           let blob = try? JSONDecoder().decode(UsageStoreBlob.self, from: data) {
            days = blob.days
            if let legacy = blob.rateWindow {
                windows["claude.session"] = ProviderQuotaWindow(
                    id: "claude.session",
                    provider: "claude",
                    label: "Claude · Session",
                    utilization: legacy.utilization,
                    resetsAt: legacy.resetsAt,
                    status: legacy.status,
                    modelRawValue: nil,
                    source: "rate_limit_event",
                    updatedAt: legacy.updatedAt
                )
            }
            save()
        }
    }

    private func save() {
        let blob = UsageStoreBlob(days: days, windows: windows, rateWindow: nil)
        if let data = try? JSONEncoder().encode(blob) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

// MARK: - Claude /usage probe

enum ClaudeUsageProbe {
    enum ProbeError: LocalizedError {
        case claudeNotFound
        case emptyOutput
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .claudeNotFound: return "Claude Code CLI not found."
            case .emptyOutput: return "Empty response from claude /usage."
            case .failed(let s): return s
            }
        }
    }

    /// Run `claude -p "/usage" --output-format json` with subscription auth env.
    static func fetchUsageText() async throws -> String {
        guard let url = ClaudeCLIPath.resolveClaudeExecutable() else {
            throw ProbeError.claudeNotFound
        }
        let resultText: String = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let proc = Process()
                    proc.executableURL = url
                    proc.arguments = ["-p", "/usage", "--output-format", "json"]
                    proc.environment = ClaudeCLIPath.subscriptionEnvironment(
                        base: ProcessInfo.processInfo.environment
                    )
                    let out = Pipe()
                    let err = Pipe()
                    proc.standardOutput = out
                    proc.standardError = err
                    try proc.run()
                    proc.waitUntilExit()
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    let errData = err.fileHandleForReading.readDataToEndOfFile()
                    if proc.terminationStatus != 0 {
                        let msg = String(data: errData, encoding: .utf8)
                            ?? String(data: data, encoding: .utf8)
                            ?? "claude exited \(proc.terminationStatus)"
                        cont.resume(throwing: ProbeError.failed(msg.trimmingCharacters(in: .whitespacesAndNewlines)))
                        return
                    }
                    guard let raw = String(data: data, encoding: .utf8), !raw.isEmpty else {
                        cont.resume(throwing: ProbeError.emptyOutput)
                        return
                    }
                    // Prefer JSON result field.
                    if let jsonData = raw.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                       let result = obj["result"] as? String {
                        cont.resume(returning: result)
                        return
                    }
                    cont.resume(returning: raw)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        return resultText
    }

    /// Parse Claude `/usage` human text into quota windows.
    static func parseWindows(from text: String) -> [ProviderQuotaWindow] {
        var windows: [ProviderQuotaWindow] = []
        let now = Date()
        let lines = text.components(separatedBy: .newlines)

        // Current session: 0% used · resets Jul 20 at 2:40am (America/Chicago)
        let sessionRe = try! NSRegularExpression(
            pattern: #"Current session:\s*(\d+(?:\.\d+)?)%\s*used\s*[·•]\s*resets\s+(.+)$"#,
            options: [.caseInsensitive]
        )
        // Current week (all models): 41% used · resets …
        let weekAllRe = try! NSRegularExpression(
            pattern: #"Current week\s*\(all models\):\s*(\d+(?:\.\d+)?)%\s*used\s*[·•]\s*resets\s+(.+)$"#,
            options: [.caseInsensitive]
        )
        // Current week (Sonnet|Opus|Haiku|Fable|…): 39% used · resets …
        let weekModelRe = try! NSRegularExpression(
            pattern: #"Current week\s*\(([^)]+)\):\s*(\d+(?:\.\d+)?)%\s*used\s*[·•]\s*resets\s+(.+)$"#,
            options: [.caseInsensitive]
        )

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let range = NSRange(trimmed.startIndex..., in: trimmed)

            if let m = sessionRe.firstMatch(in: trimmed, range: range),
               let pctR = Range(m.range(at: 1), in: trimmed),
               let resetR = Range(m.range(at: 2), in: trimmed),
               let pct = Double(trimmed[pctR]) {
                windows.append(
                    ProviderQuotaWindow(
                        id: "claude.session",
                        provider: "claude",
                        label: "Claude · Session",
                        utilization: pct / 100.0,
                        resetsAt: parseResetDate(String(trimmed[resetR])),
                        status: nil,
                        modelRawValue: nil,
                        source: "cli_usage",
                        updatedAt: now
                    )
                )
                continue
            }

            if let m = weekAllRe.firstMatch(in: trimmed, range: range),
               let pctR = Range(m.range(at: 1), in: trimmed),
               let resetR = Range(m.range(at: 2), in: trimmed),
               let pct = Double(trimmed[pctR]) {
                windows.append(
                    ProviderQuotaWindow(
                        id: "claude.week.all",
                        provider: "claude",
                        label: "Claude · Week (all models)",
                        utilization: pct / 100.0,
                        resetsAt: parseResetDate(String(trimmed[resetR])),
                        status: nil,
                        modelRawValue: nil,
                        source: "cli_usage",
                        updatedAt: now
                    )
                )
                continue
            }

            if let m = weekModelRe.firstMatch(in: trimmed, range: range),
               let nameR = Range(m.range(at: 1), in: trimmed),
               let pctR = Range(m.range(at: 2), in: trimmed),
               let resetR = Range(m.range(at: 3), in: trimmed),
               let pct = Double(trimmed[pctR]) {
                let name = String(trimmed[nameR]).trimmingCharacters(in: .whitespaces)
                if name.lowercased() == "all models" { continue }
                let model = mapUsageModelName(name)
                let idSuffix = model?.rawValue ?? name.lowercased()
                    .replacingOccurrences(of: " ", with: "_")
                windows.append(
                    ProviderQuotaWindow(
                        id: "claude.week.\(idSuffix)",
                        provider: "claude",
                        label: "Claude · Week (\(name))",
                        utilization: pct / 100.0,
                        resetsAt: parseResetDate(String(trimmed[resetR])),
                        status: nil,
                        modelRawValue: model?.rawValue,
                        source: "cli_usage",
                        updatedAt: now
                    )
                )
            }
        }
        return windows
    }

    /// Map Claude /usage model display names onto our picker options.
    /// "Fable" and similar codenames are treated as Sonnet when unknown.
    private static func mapUsageModelName(_ name: String) -> ChatModelOption? {
        let lower = name.lowercased()
        if lower.contains("opus") { return .opus }
        if lower.contains("haiku") { return .haiku }
        if lower.contains("sonnet") { return .sonnet }
        // Anthropic sometimes surfaces codenames in /usage (e.g. "Fable").
        // Prefer Sonnet as the default Max workhorse when ambiguous.
        if lower == "fable" || lower.contains("sonnet") { return .sonnet }
        return ChatModelOption.fromCLILabel(name)
    }

    /// Parse "Jul 20 at 2:40am (America/Chicago)" into Date.
    static func parseResetDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var timezone = TimeZone.current
        var body = trimmed
        if let open = trimmed.lastIndex(of: "("),
           let close = trimmed.lastIndex(of: ")"),
           open < close {
            let tzName = String(trimmed[trimmed.index(after: open)..<close])
            if let tz = TimeZone(identifier: tzName) {
                timezone = tz
            }
            body = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
        }

        // "Jul 20 at 2:40am" or "Jul 22 at 9am"
        let patterns = [
            "MMM d 'at' h:mma",
            "MMM d 'at' ha",
            "MMM d 'at' h:mm a",
            "MMM d 'at' h a",
        ]
        let year = Calendar.current.component(.year, from: Date())
        for pattern in patterns {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timezone
            f.dateFormat = pattern
            // Prepend year for parsing
            if let date = f.date(from: body) {
                var comps = Calendar.current.dateComponents(in: timezone, from: date)
                comps.year = year
                if var resolved = Calendar.current.date(from: comps) {
                    // If more than 30 days in the past, assume next year.
                    if resolved < Date().addingTimeInterval(-30 * 24 * 3600) {
                        comps.year = year + 1
                        if let next = Calendar.current.date(from: comps) {
                            resolved = next
                        }
                    }
                    return resolved
                }
            }
        }
        return nil
    }
}

// MARK: - Model helpers

extension ChatModelOption {
    static func fromCLILabel(_ raw: String?) -> ChatModelOption? {
        guard let raw else { return nil }
        let lower = raw.lowercased()
        if lower.contains("grok") { return .grok45 }
        if lower.contains("opus") { return .opus }
        if lower.contains("haiku") { return .haiku }
        if lower.contains("sonnet") || lower == "fable" { return .sonnet }
        return nil
    }
}



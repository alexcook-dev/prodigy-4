import Foundation

// MARK: - ModelProvider (PLAN.md Next Step 2 / T4)

/// Abstraction over LLM backends. V1 ships one concrete provider
/// (`ClaudeCLIProvider`); GPT/Grok land later as additional conformances
/// without reshaping the chat UI.
///
/// Not `@MainActor`: implementors own their process I/O queues and hop to
/// the main actor only for UI-facing callbacks (e.g. `hasUnviewedActivity`).
protocol ModelProvider: AnyObject {
    /// Stream one user turn. Events arrive until `.completed` or `.failed`
    /// (or the stream throws / is cancelled).
    func streamTurn(_ request: ModelTurnRequest) -> AsyncThrowingStream<ModelStreamEvent, Error>

    /// Best-effort cancel of an in-flight turn for a Project (Stop button).
    func cancelTurn(projectID: UUID)

    /// Tell the provider which Project is focused so LRU / background-activity
    /// bookkeeping can update (T9).
    func setFocusedProject(_ projectID: UUID?)

    /// Tear down the persistent CLI process for a Project (archive, delete, idle).
    func teardown(projectID: UUID)

    /// Tear down every held process (app quit).
    func teardownAll()
}

// MARK: - Request

/// One outbound user turn. The chat UI (Wave 3) builds this from SwiftData
/// and the composer; the provider never touches the ModelContext directly.
struct ModelTurnRequest: Sendable {
    /// Project this turn belongs to — keys the process LRU (T9).
    let projectID: UUID
    /// Thread within the Project (primary or Agent-scoped). Used for
    /// session_id bookkeeping on the caller side.
    let threadID: UUID
    /// Absolute path: CLI `cwd`. Session resume is cwd-scoped (D5.3 / T11).
    let workingDirectory: String
    let userMessage: String
    /// Full system-prompt **replace** body (never append). Agent persona or
    /// the default general-assistant prompt.
    let systemPrompt: String
    /// Prior CLI `session_id` for `--resume` / persistent continuity.
    let sessionID: String?
    /// Prior user/assistant turns for rehydrate-on-resume-failure (D5.3).
    /// SwiftData is the durable store; CLI transcripts are a cache.
    let history: [ModelHistoryMessage]
    /// Optional `--model` value (e.g. "sonnet", "haiku", "opus").
    let model: String?
    /// Optional `--effort` value (low / medium / high / xhigh / max).
    let effort: String?
    /// When true, a successful completion should flag the Project's
    /// `hasUnviewedActivity` so the sidebar green status-dot can light
    /// (Visual System / T9). The focused Project should pass `false`.
    let isBackground: Bool

    init(
        projectID: UUID,
        threadID: UUID,
        workingDirectory: String,
        userMessage: String,
        systemPrompt: String = ClaudeCLIDefaults.generalAssistantSystemPrompt,
        sessionID: String? = nil,
        history: [ModelHistoryMessage] = [],
        model: String? = nil,
        effort: String? = nil,
        isBackground: Bool = false
    ) {
        self.projectID = projectID
        self.threadID = threadID
        self.workingDirectory = workingDirectory
        self.userMessage = userMessage
        self.systemPrompt = systemPrompt
        self.sessionID = sessionID
        self.history = history
        self.model = model
        self.effort = effort
        self.isBackground = isBackground
    }
}

struct ModelHistoryMessage: Sendable, Equatable {
    enum Role: String, Sendable {
        case user
        case assistant
    }

    let role: Role
    let content: String
}

// MARK: - Stream events

/// Incremental events from one turn. Chat UI maps these to bubble text,
/// "Thinking…", error banners (T13), and session_id persistence.
enum ModelStreamEvent: Sendable, Equatable {
    /// `system/init` — capture `session_id` for later `--resume`.
    case sessionStarted(sessionID: String, model: String?, capabilities: [String])
    /// Model is thinking (no visible text yet). UI shows pulsing "Thinking…".
    case thinking
    /// Extended thinking / reasoning text delta (toggleable in the UI).
    case thinkingDelta(String)
    /// Visible assistant text delta (`event.delta.type == "text_delta"`).
    case textDelta(String)
    /// Advisory rate-window signal (D5.4 / Step 10); not a hard failure.
    case rateLimitInfo(
        utilization: Double?,
        resetsAt: Date?,
        status: String?,
        rateLimitType: String? = nil
    )
    /// Successful end of turn. `text` is the full assembled reply.
    case completed(
        text: String,
        sessionID: String?,
        modelLabel: String?,
        usage: TurnUsageMetrics? = nil
    )
    /// Typed failure. Partial text (if any) is on `error.partialText`.
    case failed(ProviderError)
}

/// Optional token accounting from a provider result (Claude `modelUsage`, etc.).
struct TurnUsageMetrics: Sendable, Equatable {
    var inputTokens: Int
    var outputTokens: Int

    init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
    }

    var isEmpty: Bool { inputTokens == 0 && outputTokens == 0 }
}

// MARK: - Errors (D5 / design review)

/// Categories from `system/api_retry` events plus process-level failures.
/// Chat banner copy/CTA is defined in PLAN.md; T13 renders them.
enum ProviderErrorCategory: String, Sendable, Equatable, CaseIterable {
    case authenticationFailed = "authentication_failed"
    case billingError = "billing_error"
    case rateLimit = "rate_limit"
    case overloaded = "overloaded"
    /// Subprocess exited / pipe broke mid-stream — not a typed api_retry.
    case processDied = "process_died"
    case unknown = "unknown"

    /// PLAN.md banner headline (dynamic text; CTA is separate).
    var bannerMessage: String {
        switch self {
        case .authenticationFailed:
            return "You're logged out. Sign in via Settings (Claude Max/Pro or Grok)."
        case .billingError:
            return "Billing issue with your AI subscription."
        case .rateLimit:
            return "Usage limit hit for this model."
        case .overloaded:
            return "The model is temporarily overloaded."
        case .processDied:
            return "Lost connection to the model."
        case .unknown:
            return "Something went wrong talking to the model."
        }
    }

    /// PLAN.md CTA label. `nil` means no Retry (auth can't be fixed by retry).
    var bannerCTA: String? {
        switch self {
        case .authenticationFailed:
            return "Open Settings"
        case .billingError:
            return "Details"
        case .rateLimit, .overloaded:
            return "Retry"
        case .processDied:
            return "Restart"
        case .unknown:
            return "Retry"
        }
    }

    /// Map a CLI `system/api_retry` category string (or close variant).
    static func fromCLICategory(_ raw: String?) -> ProviderErrorCategory {
        guard let raw else { return .unknown }
        let key = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        switch key {
        case "authentication_failed", "auth_failed", "unauthorized", "unauthenticated":
            return .authenticationFailed
        case "billing_error", "billing", "payment_required":
            return .billingError
        case "rate_limit", "rate_limited", "rate_limit_error":
            return .rateLimit
        case "overloaded", "overloaded_error", "unavailable":
            return .overloaded
        default:
            if let exact = ProviderErrorCategory(rawValue: key) {
                return exact
            }
            return .unknown
        }
    }
}

struct ProviderError: Error, Sendable, Equatable {
    let category: ProviderErrorCategory
    let message: String
    /// Rate-limit window reset, when known.
    let resetsAt: Date?
    /// Text streamed before the failure — preserved + tagged "[partial — kept]".
    let partialText: String?

    init(
        category: ProviderErrorCategory,
        message: String? = nil,
        resetsAt: Date? = nil,
        partialText: String? = nil
    ) {
        self.category = category
        self.message = message ?? category.bannerMessage
        self.resetsAt = resetsAt
        self.partialText = partialText
    }

    /// Rate-limit banner with optional reset time interpolated.
    var displayMessage: String {
        if category == .rateLimit, let resetsAt {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return "Claude hit its usage window (resets \(formatter.string(from: resetsAt)))."
        }
        return message
    }
}

// MARK: - Chat defaults (D5.1)

/// Shared system prompt and CLI flag constants used by `ClaudeCLIProvider`
/// and the T1 spike. Keep these in one place so quality doesn't drift.
enum ClaudeCLIDefaults {
    /// Full `--system-prompt` **replace** for plain Project chat (not Agent).
    static let generalAssistantSystemPrompt = """
    You are a helpful, general-purpose personal assistant in a native Mac workspace app. \
    You are NOT a coding agent: do not assume the user is programming, do not reach for \
    tools or repositories, and do not offer to edit files. Be clear, warm, and concise. \
    Prefer plain language over jargon. When the user asks for options, give a few concrete \
    choices with brief rationale rather than a long lecture.
    """

    /// Marker appended when rehydrating a fresh session from SwiftData history
    /// so the model treats prior turns as context, not a new unrelated chat.
    static let rehydratePreamble = """
    The following is prior conversation history recovered after the previous session \
    could not be resumed. Continue naturally from the latest user message; do not \
    re-introduce yourself or summarize the history unless asked.

    """
}

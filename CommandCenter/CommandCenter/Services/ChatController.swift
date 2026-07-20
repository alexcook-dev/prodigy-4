import Foundation
import SwiftData
import SwiftUI

// MARK: - Model / effort picker options (T5)

/// Models available in the composer picker. Routes to Claude Code CLI or Grok
/// CLI based on `providerFamily`. Changes apply on the next turn only.
enum ChatModelOption: String, CaseIterable, Identifiable, Sendable {
    case sonnet
    case opus
    case haiku
    case grok45

    var id: String { rawValue }

    enum Family: String, Sendable {
        case claude
        case grok
    }

    var family: Family {
        switch self {
        case .sonnet, .opus, .haiku: return .claude
        case .grok45: return .grok
        }
    }

    var displayName: String {
        switch self {
        case .sonnet: return "Sonnet"
        case .opus: return "Opus"
        case .haiku: return "Haiku"
        case .grok45: return "Grok 4.5"
        }
    }

    /// Composer pill: "Claude · Sonnet" / "Grok · 4.5"
    var pillLabel: String {
        switch family {
        case .claude: return "Claude · \(displayName)"
        case .grok: return displayName
        }
    }

    /// "from" label on assistant bubbles when the CLI doesn't return a model.
    var messageLabel: String { pillLabel }

    /// Value passed as `--model` to the selected backend.
    var cliValue: String {
        switch self {
        case .sonnet: return "sonnet"
        case .opus: return "opus"
        case .haiku: return "haiku"
        case .grok45: return "grok-4.5"
        }
    }
}

/// Claude Code effort levels (`--effort`). Cross-provider mapping is deferred.
enum ChatEffortOption: String, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra high"
        case .max: return "Max"
        }
    }

    /// Composer pill: "Effort: High"
    var pillLabel: String { "Effort: \(displayName)" }

    /// Appended to the "from" label: "Claude · Sonnet · High effort"
    var messageSuffix: String { "\(displayName) effort" }

    var cliValue: String { rawValue }
}

// MARK: - ChatController (T5 + T13)

/// Owns composer state, model/effort selection, in-flight streaming, and the
/// category-specific error banner. Persists completed/partial messages into
/// SwiftData; the provider never touches the ModelContext.
@MainActor
@Observable
final class ChatController {
    // MARK: Composer

    var composerText: String = ""
    var selectedModel: ChatModelOption = .sonnet
    var selectedEffort: ChatEffortOption = .high
    /// Focus token bumped when discuss-in-chat / send-failed recovery wants the field focused.
    var composerFocusToken: UInt = 0

    // MARK: Streaming (ephemeral until complete / fail)

    enum StreamPhase: Equatable {
        case idle
        case thinking
        case streaming
    }

    private(set) var streamPhase: StreamPhase = .idle
    private(set) var streamingText: String = ""
    /// Extended thinking / reasoning text for the in-flight turn.
    private(set) var streamingReasoning: String = ""
    private(set) var streamingModelLabel: String?
    private(set) var streamingProjectID: UUID?
    private(set) var streamingThreadID: UUID?
    /// User text for the in-flight turn (usage meter input-size estimate).
    private var streamingUserText: String = ""
    /// When true, show reasoning blocks on assistant messages / live stream.
    /// Bound from the chat top-bar toggle (persisted via AppStorage in the view).
    var showReasoning: Bool = true

    // MARK: Error banner (T13) — scoped to the project/thread that failed

    private(set) var activeError: ProviderError?
    private(set) var failedProjectID: UUID?
    private(set) var failedThreadID: UUID?
    /// Last user text for Retry / Restart after a failure.
    private var lastFailedUserText: String?
    var errorDetailsExpanded: Bool = false

    // MARK: Internals

    private var streamTask: Task<Void, Never>?
    private let provider: ModelProvider

    /// Mirrored from sidebar selection so a turn that finishes after the user
    /// navigated away can set `hasUnviewedActivity` (T9 / mid-stream switch).
    var focusedProjectID: UUID?

    var isBusy: Bool { streamPhase != .idle }

    init(provider: ModelProvider = RoutingModelProvider.shared) {
        self.provider = provider
    }

    // MARK: - Queries for the current surface

    func isStreaming(projectID: UUID, threadID: UUID) -> Bool {
        isBusy
            && streamingProjectID == projectID
            && streamingThreadID == threadID
    }

    func error(for projectID: UUID, threadID: UUID) -> ProviderError? {
        guard failedProjectID == projectID, failedThreadID == threadID else { return nil }
        return activeError
    }

    // MARK: - Composer helpers

    /// Append plain text (⌘⏎ discuss-in-chat reference). Focuses the field.
    func insertComposerText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if composerText.isEmpty {
            composerText = trimmed
        } else if composerText.hasSuffix("\n") {
            composerText += trimmed
        } else {
            composerText += "\n" + trimmed
        }
        composerFocusToken &+= 1
    }

    func applySuggestion(_ text: String) {
        composerText = text
        composerFocusToken &+= 1
    }

    // MARK: - Send / stop

    /// Send the current composer text for the active Project/thread.
    func send(
        project: WorkspaceProject,
        thread: ChatThread,
        agent: Agent?,
        context: ModelContext,
        isBackground: Bool = false
    ) {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        beginTurn(
            userText: text,
            project: project,
            thread: thread,
            agent: agent,
            context: context,
            isBackground: isBackground,
            clearComposer: true
        )
    }

    /// Retry / Restart after a typed failure — re-sends the failed user turn.
    func retryFailedTurn(
        project: WorkspaceProject,
        thread: ChatThread,
        agent: Agent?,
        context: ModelContext
    ) {
        guard let text = lastFailedUserText, !text.isEmpty else { return }
        guard !isBusy else { return }

        // processDied Restart: drop the broken CLI process first so the next
        // turn spawns cleanly (T13 CTA "Restart").
        if activeError?.category == .processDied {
            provider.teardown(projectID: project.id)
        }

        clearError()
        beginTurn(
            userText: text,
            project: project,
            thread: thread,
            agent: agent,
            context: context,
            isBackground: false,
            clearComposer: false,
            // Don't re-insert a duplicate user bubble if the failed turn already
            // saved one (normal path). Only re-insert when nothing is there
            // (edge case: failure before user message was persisted).
            skipUserMessageIfDuplicate: true
        )
    }

    func stop(projectID: UUID) {
        provider.cancelTurn(projectID: projectID)
        // Provider yields .failed(processDied, "Stopped.") with partial text;
        // handleFailed will persist the partial and soft-clear (no banner for Stop).
    }

    func dismissError() {
        clearError()
    }

    // MARK: - Error CTA (T13)

    enum ErrorCTAAction {
        /// authentication_failed — open Terminal with `claude auth login --claudeai`
        /// so the user signs in with Max/Pro (Claude.ai subscription).
        case signInWithClaude
        /// billing_error — toggle Details expansion.
        case showDetails
        /// rate_limit / overloaded — Retry the last user turn.
        case retry
        /// process_died — Restart the CLI process and retry.
        case restart
    }

    func ctaAction(for error: ProviderError) -> ErrorCTAAction {
        switch error.category {
        case .authenticationFailed:
            return .signInWithClaude
        case .billingError:
            return .showDetails
        case .rateLimit, .overloaded, .unknown:
            return .retry
        case .processDied:
            return .restart
        }
    }

    func performCTA(
        _ action: ErrorCTAAction,
        project: WorkspaceProject?,
        thread: ChatThread?,
        agent: Agent?,
        context: ModelContext,
        focusTerminal: () -> Void
    ) {
        switch action {
        case .signInWithClaude:
            // Open Settings so the user can auth Claude and/or Grok.
            NotificationCenter.default.post(name: .prodigyOpenSettings, object: nil)
            focusTerminal()
        case .showDetails:
            errorDetailsExpanded.toggle()
        case .retry, .restart:
            guard let project, let thread else { return }
            retryFailedTurn(
                project: project,
                thread: thread,
                agent: agent,
                context: context
            )
        }
    }

    // MARK: - Internals

    private func beginTurn(
        userText: String,
        project: WorkspaceProject,
        thread: ChatThread,
        agent: Agent?,
        context: ModelContext,
        isBackground: Bool,
        clearComposer: Bool,
        skipUserMessageIfDuplicate: Bool = false
    ) {
        streamTask?.cancel()
        streamTask = nil

        // History for rehydrate: prior turns only (before this user message).
        // ModelTurnRequest.make comment: history excludes the just-typed user msg.
        let priorHistory: [ModelHistoryMessage] = thread.sortedMessages.compactMap { msg in
            switch msg.role {
            case .user: return ModelHistoryMessage(role: .user, content: msg.content)
            case .assistant: return ModelHistoryMessage(role: .assistant, content: msg.content)
            case .system: return nil
            }
        }

        let alreadyHasUser: Bool = {
            guard skipUserMessageIfDuplicate else { return false }
            return thread.sortedMessages.last.map {
                $0.role == .user && $0.content == userText
            } ?? false
        }()

        if !alreadyHasUser {
            let userMsg = Message(role: .user, content: userText, thread: thread)
            context.insert(userMsg)
            thread.messages.append(userMsg)
        }

        thread.updatedAt = .now
        project.lastActiveAt = .now
        streamingUserText = userText
        // Promote quick-chat once it has real content.
        if project.isQuickChat {
            ProjectFactory.promoteToSidebar(project)
        }
        try? context.save()

        if clearComposer {
            composerText = ""
        }

        clearError()
        streamPhase = .thinking
        streamingText = ""
        streamingReasoning = ""
        streamingModelLabel = makeModelLabel(cliModel: nil)
        streamingProjectID = project.id
        streamingThreadID = thread.id
        lastFailedUserText = userText
        // Keep the composer focused after send so terminal doesn't steal the caret.
        composerFocusToken &+= 1

        let systemPrompt = Self.composeSystemPrompt(agent: agent)

        let request = ModelTurnRequest(
            projectID: project.id,
            threadID: thread.id,
            workingDirectory: project.folderPath,
            userMessage: userText,
            systemPrompt: systemPrompt,
            sessionID: thread.cliSessionID,
            history: priorHistory,
            model: selectedModel.cliValue,
            effort: selectedEffort.cliValue,
            isBackground: isBackground
        )

        // Capture IDs — SwiftData models are safe on MainActor while registered.
        let projectID = project.id
        let threadID = thread.id

        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = self.provider.streamTurn(request)
            do {
                for try await event in stream {
                    if Task.isCancelled { break }
                    self.handleEvent(
                        event,
                        project: project,
                        thread: thread,
                        context: context,
                        projectID: projectID,
                        threadID: threadID
                    )
                }
                // Stream finished without .completed / .failed (e.g. cancel with no event).
                if self.streamPhase != .idle,
                   self.streamingProjectID == projectID,
                   self.streamingThreadID == threadID {
                    self.finishIdle()
                }
            } catch is CancellationError {
                // Stop / task cancel — provider usually already yielded .failed.
                if self.streamPhase != .idle {
                    self.finishIdle()
                }
            } catch let error as ProviderError {
                self.handleFailed(
                    error,
                    project: project,
                    thread: thread,
                    context: context,
                    projectID: projectID,
                    threadID: threadID
                )
            } catch {
                self.handleFailed(
                    ProviderError(
                        category: .processDied,
                        message: error.localizedDescription,
                        partialText: self.streamingText.isEmpty ? nil : self.streamingText
                    ),
                    project: project,
                    thread: thread,
                    context: context,
                    projectID: projectID,
                    threadID: threadID
                )
            }
        }
    }

    private func handleEvent(
        _ event: ModelStreamEvent,
        project: WorkspaceProject,
        thread: ChatThread,
        context: ModelContext,
        projectID: UUID,
        threadID: UUID
    ) {
        switch event {
        case .sessionStarted(let sessionID, let model, _):
            thread.cliSessionID = sessionID
            if let model {
                streamingModelLabel = makeModelLabel(cliModel: model)
            }
            try? context.save()

        case .thinking:
            if streamPhase == .thinking || streamPhase == .idle {
                streamPhase = .thinking
            }

        case .thinkingDelta(let delta):
            if streamPhase == .idle || streamPhase == .thinking {
                streamPhase = .thinking
            }
            streamingReasoning += delta

        case .textDelta(let delta):
            streamPhase = .streaming
            streamingText += delta

        case .rateLimitInfo(let utilization, let resetsAt, let status, let rateLimitType):
            UsageMeterService.shared.updateFromRateLimitEvent(
                utilization: utilization,
                resetsAt: resetsAt,
                status: status,
                rateLimitType: rateLimitType
            )

        case .completed(let text, let sessionID, let modelLabel, let usage):
            if let sessionID {
                thread.cliSessionID = sessionID
            }
            let finalText = text.isEmpty ? streamingText : text
            let label = modelLabel.map { makeModelLabel(cliModel: $0) }
                ?? streamingModelLabel
                ?? selectedModel.messageLabel
            let reasoning = streamingReasoning.trimmingCharacters(in: .whitespacesAndNewlines)
            let assistant = Message(
                role: .assistant,
                content: finalText,
                isPartial: false,
                modelLabel: label,
                reasoning: reasoning.isEmpty ? nil : reasoning,
                thread: thread
            )
            context.insert(assistant)
            thread.messages.append(assistant)
            thread.updatedAt = .now
            // User switched Projects mid-stream → green unread-activity dot (T9).
            if focusedProjectID != projectID {
                project.hasUnviewedActivity = true
            }
            try? context.save()
            recordUsage(
                modelLabel: modelLabel,
                finalText: finalText,
                usage: usage
            )
            // Refresh authoritative Claude Max/Pro windows after each turn.
            if selectedModel.family == .claude {
                Task { await UsageMeterService.shared.syncClaudeUsageFromCLI() }
            }
            lastFailedUserText = nil
            finishIdle()

        case .failed(let error):
            handleFailed(
                error,
                project: project,
                thread: thread,
                context: context,
                projectID: projectID,
                threadID: threadID
            )
        }
    }

    private func handleFailed(
        _ error: ProviderError,
        project: WorkspaceProject,
        thread: ChatThread,
        context: ModelContext,
        projectID: UUID,
        threadID: UUID
    ) {
        // Prefer partial from the error; fall back to what we assembled locally.
        let partial = error.partialText
            ?? (streamingText.isEmpty ? nil : streamingText)

        if let partial, !partial.isEmpty {
            let label = streamingModelLabel ?? selectedModel.messageLabel
            let reasoning = streamingReasoning.trimmingCharacters(in: .whitespacesAndNewlines)
            let assistant = Message(
                role: .assistant,
                content: partial,
                isPartial: true,
                modelLabel: label,
                reasoning: reasoning.isEmpty ? nil : reasoning,
                thread: thread
            )
            context.insert(assistant)
            thread.messages.append(assistant)
            thread.updatedAt = .now
            try? context.save()
            // Count partial replies too so Stop still contributes to the gauge.
            recordUsage(modelLabel: nil, finalText: partial, usage: nil)
        }

        // Intentional Stop: keep partial, no scary banner.
        let isSoftStop = error.category == .processDied
            && error.message.localizedCaseInsensitiveContains("stopped")

        if isSoftStop {
            lastFailedUserText = nil
            clearError()
        } else {
            activeError = error
            failedProjectID = projectID
            failedThreadID = threadID
            errorDetailsExpanded = false
            // lastFailedUserText already set at send time for Retry/Restart.
        }

        finishIdle()
        _ = project // keep project referenced for future activity flags
    }

    private func recordUsage(
        modelLabel: String?,
        finalText: String,
        usage: TurnUsageMetrics?
    ) {
        let model = ChatModelOption.fromCLILabel(modelLabel)
            ?? ChatModelOption.fromCLILabel(streamingModelLabel)
            ?? selectedModel
        UsageMeterService.shared.recordTurn(
            model: model,
            inputTokens: usage.flatMap { $0.inputTokens > 0 ? $0.inputTokens : nil },
            outputTokens: usage.flatMap { $0.outputTokens > 0 ? $0.outputTokens : nil },
            inputChars: streamingUserText.count,
            outputChars: finalText.count
        )
    }

    private func finishIdle() {
        streamPhase = .idle
        streamingText = ""
        streamingReasoning = ""
        streamingModelLabel = nil
        streamingProjectID = nil
        streamingThreadID = nil
        streamingUserText = ""
        streamTask = nil
    }

    private func clearError() {
        activeError = nil
        failedProjectID = nil
        failedThreadID = nil
        errorDetailsExpanded = false
    }

    private func makeModelLabel(cliModel: String?) -> String {
        let modelPart: String
        if let cliModel, !cliModel.isEmpty {
            // CLI often returns "claude-sonnet-4-…" — keep a short readable form.
            let lower = cliModel.lowercased()
            if lower.contains("opus") {
                modelPart = "Claude · Opus"
            } else if lower.contains("haiku") {
                modelPart = "Claude · Haiku"
            } else if lower.contains("sonnet") {
                modelPart = "Claude · Sonnet"
            } else {
                modelPart = "Claude · \(cliModel)"
            }
        } else {
            modelPart = selectedModel.messageLabel
        }
        return "\(modelPart) · \(selectedEffort.messageSuffix)"
    }

    /// Base persona (agent or access-mode default) + shared skills catalog + visuals prefs.
    /// Skills are injected for **both** Claude and Grok so they stay in sync.
    static func composeSystemPrompt(agent: Agent?) -> String {
        let defaults = UserDefaults.standard
        let fullAccess = defaults.bool(forKey: AppStorageKey.fullMacAccess)
        let loadTools: Bool = {
            if fullAccess { return true }
            if defaults.object(forKey: AppStorageKey.loadToolsWhenNeeded) == nil { return true }
            return defaults.bool(forKey: AppStorageKey.loadToolsWhenNeeded)
        }()

        let base: String
        if let agent, !agent.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            base = agent.systemPrompt
        } else if fullAccess {
            base = ProdigyAccessSettings.fullAccessSystemPrompt
        } else if loadTools {
            base = """
            You are a helpful personal assistant in Prodigy with tools available when needed. \
            Prefer the lightest tool for the job. Use skills when they match. Be clear and concise.
            """
        } else {
            base = ProdigyAccessSettings.restrictedSystemPrompt
        }

        var extras: [String] = []
        if ProdigyPrefs.bool(.connectorSearch, default: true) {
            extras.append(
                "Connector search is on: when relevant, search installed skills/connectors " +
                "(~/.prodigy/skills, ~/.claude/skills, ~/.grok/skills) and surface matching ones."
            )
        }
        if ProdigyPrefs.bool(.artifactsEnabled, default: true) {
            extras.append(
                "Artifacts are on: for substantial code, documents, or designs, produce a clear " +
                "self-contained artifact block the user can keep alongside chat."
            )
        }
        if ProdigyPrefs.bool(.aiPoweredArtifacts, default: true) {
            extras.append(
                "AI-powered artifacts are on: interactive apps/docs inside artifacts may call the model."
            )
        }
        if ProdigyPrefs.bool(.inlineVisualizations, default: true) {
            extras.append(
                "Inline visualizations are on: prefer mermaid/ASCII charts or structured tables " +
                "for interactive charts and diagrams in the conversation."
            )
        }
        if ProdigyPrefs.bool(.switchModelsWhenFlagged, default: true) {
            extras.append(
                "If a response would be blocked by safety policy, say so briefly so the app can " +
                "offer a model switch — do not refuse silently."
            )
        }

        let skills = ProdigySkillsService.shared.systemPromptSkillsBlock()
        var result = base
        if !extras.isEmpty {
            result += "\n\n## Prodigy preferences\n" + extras.map { "- \($0)" }.joined(separator: "\n")
        }
        if !skills.isEmpty {
            result += "\n" + skills
        }
        return result
    }
}

/// Typed UserDefaults helpers for Settings toggles with explicit defaults.
enum ProdigyPrefs {
    enum Key {
        case connectorSearch
        case switchModelsWhenFlagged
        case artifactsEnabled
        case aiPoweredArtifacts
        case inlineVisualizations
        case loadToolsWhenNeeded

        var storageKey: String {
            switch self {
            case .connectorSearch: return AppStorageKey.connectorSearch
            case .switchModelsWhenFlagged: return AppStorageKey.switchModelsWhenFlagged
            case .artifactsEnabled: return AppStorageKey.artifactsEnabled
            case .aiPoweredArtifacts: return AppStorageKey.aiPoweredArtifacts
            case .inlineVisualizations: return AppStorageKey.inlineVisualizations
            case .loadToolsWhenNeeded: return AppStorageKey.loadToolsWhenNeeded
            }
        }
    }

    static func bool(_ key: Key, default defaultValue: Bool) -> Bool {
        if UserDefaults.standard.object(forKey: key.storageKey) == nil {
            return defaultValue
        }
        return UserDefaults.standard.bool(forKey: key.storageKey)
    }
}

import Foundation
import SwiftData
import SwiftUI

// MARK: - Model / effort picker options (T5)

/// Claude CLI `--model` values surfaced in the composer. Changes apply on the
/// next turn only (PLAN.md Step 3).
enum ChatModelOption: String, CaseIterable, Identifiable, Sendable {
    case sonnet
    case opus
    case haiku

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sonnet: return "Sonnet"
        case .opus: return "Opus"
        case .haiku: return "Haiku"
        }
    }

    /// Composer pill: "Claude · Sonnet"
    var pillLabel: String { "Claude · \(displayName)" }

    /// "from" label on assistant bubbles when the CLI doesn't return a model.
    var messageLabel: String { "Claude · \(displayName)" }

    /// Value passed as `--model`.
    var cliValue: String { rawValue }
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
    private(set) var streamingModelLabel: String?
    private(set) var streamingProjectID: UUID?
    private(set) var streamingThreadID: UUID?

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

    init(provider: ModelProvider = ClaudeCLIProvider.shared) {
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
        /// authentication_failed — switch to terminal so the user can re-auth.
        case openTerminalToReauth
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
            return .openTerminalToReauth
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
        case .openTerminalToReauth:
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
        streamingModelLabel = makeModelLabel(cliModel: nil)
        streamingProjectID = project.id
        streamingThreadID = thread.id
        lastFailedUserText = userText

        let systemPrompt = (agent?.systemPrompt.isEmpty == false)
            ? agent!.systemPrompt
            : ClaudeCLIDefaults.generalAssistantSystemPrompt

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

        case .textDelta(let delta):
            streamPhase = .streaming
            streamingText += delta

        case .rateLimitInfo:
            // Advisory only — usage display is Step 10 / T8 (deferred).
            break

        case .completed(let text, let sessionID, let modelLabel):
            if let sessionID {
                thread.cliSessionID = sessionID
            }
            let finalText = text.isEmpty ? streamingText : text
            let label = modelLabel.map { makeModelLabel(cliModel: $0) }
                ?? streamingModelLabel
                ?? selectedModel.messageLabel
            let assistant = Message(
                role: .assistant,
                content: finalText,
                isPartial: false,
                modelLabel: label,
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
            let assistant = Message(
                role: .assistant,
                content: partial,
                isPartial: true,
                modelLabel: label,
                thread: thread
            )
            context.insert(assistant)
            thread.messages.append(assistant)
            thread.updatedAt = .now
            try? context.save()
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

    private func finishIdle() {
        streamPhase = .idle
        streamingText = ""
        streamingModelLabel = nil
        streamingProjectID = nil
        streamingThreadID = nil
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
}

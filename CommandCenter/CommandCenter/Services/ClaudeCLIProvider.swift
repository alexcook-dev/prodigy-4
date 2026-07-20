import Foundation

// MARK: - ClaudeCLIProvider (T4 + T9)

/// Drives the installed `claude` CLI as a local subprocess.
///
/// **Primary path (D5.2):** one long-running process per conversation using
/// `--input-format stream-json --output-format stream-json` over stdio.
/// Multiple turns reuse the same process (no per-turn cold start).
///
/// **Fallback:** spawn-per-turn (`-p` + `--resume`) when the Project is beyond
/// the LRU cap, the persistent process misbehaves, or a forced one-shot is
/// needed after resume failure rehydrate.
///
/// **Never `--bare`** — bare mode skips OAuth/keychain and breaks subscription
/// auth (PLAN.md D5.1).
///
/// **Process lifecycle (T9):** at most `maxPersistentProcesses` (3) CLI
/// processes stay alive — the focused Project plus up to two backgrounded
/// ones, LRU-evicted. Idle processes are torn down after `idleTimeout`.
/// A background reply finishing invokes `onBackgroundReplyCompleted` so the
/// UI can set `WorkspaceProject.hasUnviewedActivity`.
final class ClaudeCLIProvider: ModelProvider, @unchecked Sendable {

    // MARK: Configuration

    /// Cap on concurrent persistent CLI processes (focused + background).
    static let maxPersistentProcesses = 3
    /// Tear down a non-busy process after this much idle time.
    static let idleTimeout: TimeInterval = 15 * 60
    /// Path to the `claude` binary. Defaults to PATH lookup.
    var claudeExecutableURL: URL?

    /// Called on the main actor when a turn completes while the Project was
    /// backgrounded — wire this to set `hasUnviewedActivity = true` (T9).
    var onBackgroundReplyCompleted: (@MainActor @Sendable (UUID) -> Void)?

    /// When true, never keep processes around — always spawn-per-turn.
    /// Useful if persistent mode is misbehaving in the field.
    var forceSpawnPerTurn: Bool = false

    // MARK: State

    private let lock = NSLock()
    private var sessions: [UUID: ClaudeCLISession] = [:]
    /// LRU order: least-recently-used at index 0, most-recent at end.
    private var lruOrder: [UUID] = []
    private var focusedProjectID: UUID?
    private var idleTimers: [UUID: DispatchSourceTimer] = [:]
    private let ioQueue = DispatchQueue(label: "com.commandcenter.claude-cli", qos: .userInitiated)

    init(
        claudeExecutableURL: URL? = nil,
        onBackgroundReplyCompleted: (@MainActor @Sendable (UUID) -> Void)? = nil
    ) {
        self.claudeExecutableURL = claudeExecutableURL
        self.onBackgroundReplyCompleted = onBackgroundReplyCompleted
    }

    deinit {
        teardownAll()
    }

    // MARK: - ModelProvider

    func streamTurn(_ request: ModelTurnRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runTurn(request, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func cancelTurn(projectID: UUID) {
        lock.lock()
        let session = sessions[projectID]
        lock.unlock()
        session?.cancelInFlight()
    }

    func setFocusedProject(_ projectID: UUID?) {
        lock.lock()
        focusedProjectID = projectID
        if let projectID {
            touchLRU_locked(projectID)
        }
        lock.unlock()
    }

    /// T14 launch resume: best-effort warm of a Project's persistent CLI process
    /// via the D5.3 session-resume path (`--resume` + rehydrate-on-failure).
    ///
    /// Called after auto-selecting the last-active Project on app launch so the
    /// next user turn doesn't pay cold-start. No-op when there is no `sessionID`
    /// yet (empty/new thread). Failures are swallowed — the first real turn
    /// retries the same path.
    func prepareLaunchResume(
        projectID: UUID,
        workingDirectory: String,
        sessionID: String?,
        systemPrompt: String = ClaudeCLIDefaults.generalAssistantSystemPrompt,
        model: String? = nil,
        effort: String? = nil
    ) {
        setFocusedProject(projectID)
        guard let sessionID, !sessionID.isEmpty else { return }

        // `obtainPersistentSession` + `startPersistent` block on the I/O queue;
        // never run that on the main actor.
        ioQueue.async { [weak self] in
            guard let self else { return }
            let request = ModelTurnRequest(
                projectID: projectID,
                threadID: projectID,
                workingDirectory: workingDirectory,
                userMessage: "",
                systemPrompt: systemPrompt,
                sessionID: sessionID,
                model: model,
                effort: effort
            )
            do {
                _ = try self.obtainPersistentSession(for: request)
            } catch {
                // Best-effort: first real turn re-enters D5.3 resume/rehydrate.
            }
        }
    }

    func teardown(projectID: UUID) {
        lock.lock()
        let session = sessions.removeValue(forKey: projectID)
        lruOrder.removeAll { $0 == projectID }
        cancelIdleTimer_locked(projectID)
        lock.unlock()
        session?.terminate()
    }

    func teardownAll() {
        lock.lock()
        let all = Array(sessions.values)
        sessions.removeAll()
        lruOrder.removeAll()
        for timer in idleTimers.values { timer.cancel() }
        idleTimers.removeAll()
        lock.unlock()
        for session in all {
            session.terminate()
        }
    }

    // MARK: - Turn orchestration

    private func runTurn(
        _ request: ModelTurnRequest,
        continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation
    ) async throws {
        touchAndEnforceLRU(projectID: request.projectID)

        let usePersistent = shouldUsePersistent(for: request.projectID)

        if usePersistent {
            do {
                let succeeded = try await runPersistentTurn(request, continuation: continuation)
                scheduleIdleTeardown(projectID: request.projectID)
                if succeeded {
                    notifyBackgroundIfNeeded(request)
                }
                return
            } catch let error as ProviderError where error.category == .processDied {
                // Persistent process died mid-flight — surface the error and drop
                // the broken session. UI shows Restart / Retry CTA (T13).
                teardown(projectID: request.projectID)
                yieldFailed(continuation, error)
                return
            } catch {
                throw error
            }
        }

        // Spawn-per-turn path (beyond LRU cap, force flag, or after eviction).
        let succeeded = try await runSpawnPerTurn(request, continuation: continuation)
        if succeeded {
            notifyBackgroundIfNeeded(request)
        }
    }

    private func notifyBackgroundIfNeeded(_ request: ModelTurnRequest) {
        guard request.isBackground else { return }
        let projectID = request.projectID
        let callback = onBackgroundReplyCompleted
        Task { @MainActor in
            callback?(projectID)
        }
    }

    private func yieldFailed(
        _ continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation,
        _ error: ProviderError
    ) {
        continuation.yield(.failed(error))
    }

    // MARK: Persistent process path

    /// Returns `true` when the turn completed successfully (not a failed event).
    @discardableResult
    private func runPersistentTurn(
        _ request: ModelTurnRequest,
        continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation
    ) async throws -> Bool {
        let session = try obtainPersistentSession(for: request)

        // If we have a stored session_id but the process is fresh (just spawned
        // without resume — e.g. process was idle-torn-down), the session was
        // started with --resume when possible. If resume failed at spawn, the
        // session is marked for rehydrate on first turn.
        if session.needsRehydrate {
            return try await rehydrateThenSend(
                session: session,
                request: request,
                continuation: continuation
            )
        }

        let outcome = try await session.sendUserMessage(
            request.userMessage,
            continuation: continuation
        )

        if case .resumeFailed = outcome {
            // Rare: process was resumed at spawn but CLI still rejects the turn.
            session.markNeedsRehydrate()
            return try await rehydrateThenSend(
                session: session,
                request: request,
                continuation: continuation
            )
        }
        // Outcome.success still may have yielded .failed (process died, api_retry).
        // Background-activity only cares about successful completions; the
        // session tracks that via whether the last event was .completed.
        return session.lastTurnSucceeded
    }

    @discardableResult
    private func rehydrateThenSend(
        session: ClaudeCLISession,
        request: ModelTurnRequest,
        continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation
    ) async throws -> Bool {
        // Tear down the (possibly broken) process and start a fresh one without
        // --resume, replaying SwiftData history into the first user message.
        teardown(projectID: request.projectID)

        let rehydrated = try obtainPersistentSession(
            for: request,
            forceNoResume: true
        )
        let prompt = Self.rehydratePrompt(request: request)
        let outcome = try await rehydrated.sendUserMessage(
            prompt,
            continuation: continuation
        )
        if case .resumeFailed = outcome {
            // Fresh process shouldn't resume-fail; treat as unknown.
            let err = ProviderError(
                category: .unknown,
                message: "Could not start a new Claude session after resume failure."
            )
            continuation.yield(.failed(err))
            rehydrated.clearNeedsRehydrate()
            return false
        }
        rehydrated.clearNeedsRehydrate()
        return rehydrated.lastTurnSucceeded
    }

    /// Build a single user message that embeds history so a new CLI session
    /// continues the conversation after transcript GC (D5.3).
    static func rehydratePrompt(request: ModelTurnRequest) -> String {
        guard !request.history.isEmpty else {
            return request.userMessage
        }
        var parts: [String] = [ClaudeCLIDefaults.rehydratePreamble, "---", ""]
        for msg in request.history {
            let label = msg.role == .user ? "User" : "Assistant"
            parts.append("\(label): \(msg.content)")
            parts.append("")
        }
        parts.append("User: \(request.userMessage)")
        return parts.joined(separator: "\n")
    }

    private func obtainPersistentSession(
        for request: ModelTurnRequest,
        forceNoResume: Bool = false
    ) throws -> ClaudeCLISession {
        let fullAccess = Self.isFullMacAccessEnabled()
        lock.lock()
        if let existing = sessions[request.projectID], existing.isAlive {
            // Access mode change requires a new process (tools/permissions flags).
            if existing.fullMacAccess == fullAccess {
                touchLRU_locked(request.projectID)
                cancelIdleTimer_locked(request.projectID)
                lock.unlock()
                return existing
            }
            sessions.removeValue(forKey: request.projectID)
            lruOrder.removeAll { $0 == request.projectID }
            cancelIdleTimer_locked(request.projectID)
            lock.unlock()
            existing.terminate()
        } else {
            // Drop dead entry if any.
            sessions.removeValue(forKey: request.projectID)
            lock.unlock()
        }

        // Evict before spawning so we stay ≤ cap.
        enforceCap(reserving: request.projectID)

        let executable = resolveClaudeExecutable()
        let resumeID = forceNoResume ? nil : request.sessionID
        let session = ClaudeCLISession(
            projectID: request.projectID,
            workingDirectory: request.workingDirectory,
            systemPrompt: request.systemPrompt,
            model: request.model,
            effort: request.effort,
            resumeSessionID: resumeID,
            executableURL: executable,
            queue: ioQueue,
            fullMacAccess: fullAccess
        )

        do {
            try session.startPersistent()
        } catch let error as ClaudeCLISession.StartError {
            if error == .resumeFailed, resumeID != nil {
                // Transcript GC'd — spawn fresh and flag rehydrate.
                let fresh = ClaudeCLISession(
                    projectID: request.projectID,
                    workingDirectory: request.workingDirectory,
                    systemPrompt: request.systemPrompt,
                    model: request.model,
                    effort: request.effort,
                    resumeSessionID: nil,
                    executableURL: executable,
                    queue: ioQueue,
                    fullMacAccess: fullAccess
                )
                try fresh.startPersistent()
                fresh.markNeedsRehydrate()
                lock.lock()
                sessions[request.projectID] = fresh
                touchLRU_locked(request.projectID)
                lock.unlock()
                return fresh
            }
            throw ProviderError(category: .processDied, message: error.localizedDescription)
        }

        lock.lock()
        sessions[request.projectID] = session
        touchLRU_locked(request.projectID)
        lock.unlock()
        return session
    }

    // MARK: Spawn-per-turn path

    /// Returns `true` when the turn completed successfully.
    @discardableResult
    private func runSpawnPerTurn(
        _ request: ModelTurnRequest,
        continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation
    ) async throws -> Bool {
        let executable = resolveClaudeExecutable()
        var attemptResume = request.sessionID != nil
        var usedRehydrate = false

        let fullAccess = Self.isFullMacAccessEnabled()
        for _ in 0..<2 {
            let session = ClaudeCLISession(
                projectID: request.projectID,
                workingDirectory: request.workingDirectory,
                systemPrompt: request.systemPrompt,
                model: request.model,
                effort: request.effort,
                resumeSessionID: attemptResume ? request.sessionID : nil,
                executableURL: executable,
                queue: ioQueue,
                fullMacAccess: fullAccess
            )

            let prompt: String
            if usedRehydrate {
                prompt = Self.rehydratePrompt(request: request)
            } else {
                prompt = request.userMessage
            }

            do {
                let outcome = try await session.runOneShot(
                    prompt: prompt,
                    continuation: continuation
                )
                if case .resumeFailed = outcome, attemptResume {
                    // D5.3: rehydrate from SwiftData and retry once without --resume.
                    attemptResume = false
                    usedRehydrate = true
                    continue
                }
                return session.lastTurnSucceeded
            } catch let error as ProviderError {
                continuation.yield(.failed(error))
                return false
            }
        }
        return false
    }

    // MARK: LRU / idle

    private func shouldUsePersistent(for projectID: UUID) -> Bool {
        if forceSpawnPerTurn { return false }
        lock.lock()
        defer { lock.unlock() }
        // Already has a live session → keep using it.
        if let s = sessions[projectID], s.isAlive { return true }
        // Room under the cap (counting this project if we spawn) → persistent.
        let others = sessions.keys.filter { $0 != projectID }.count
        return others < Self.maxPersistentProcesses
    }

    private func touchAndEnforceLRU(projectID: UUID) {
        lock.lock()
        touchLRU_locked(projectID)
        lock.unlock()
        enforceCap(reserving: projectID)
    }

    private func touchLRU_locked(_ projectID: UUID) {
        lruOrder.removeAll { $0 == projectID }
        lruOrder.append(projectID)
    }

    /// Evict least-recently-used sessions so there is room under the cap.
    /// When `reserving` is not yet in the map, leave one free slot for it.
    /// Prefer idle (not busy) victims; never evict `reserving`.
    private func enforceCap(reserving: UUID) {
        lock.lock()
        var victims: [ClaudeCLISession] = []
        // If reserving already has a session, allow up to max; otherwise
        // free a slot so the upcoming spawn stays ≤ max.
        let targetCount = sessions[reserving] == nil
            ? Self.maxPersistentProcesses - 1
            : Self.maxPersistentProcesses

        while sessions.count > max(0, targetCount) {
            let candidateID = lruOrder.first { id in
                id != reserving && !(sessions[id]?.isBusy ?? false)
            } ?? lruOrder.first { $0 != reserving }

            guard let victimID = candidateID,
                  let victim = sessions.removeValue(forKey: victimID)
            else { break }

            lruOrder.removeAll { $0 == victimID }
            cancelIdleTimer_locked(victimID)
            victims.append(victim)
        }
        lock.unlock()
        for v in victims {
            v.terminate()
        }
    }

    private func scheduleIdleTeardown(projectID: UUID) {
        lock.lock()
        cancelIdleTimer_locked(projectID)
        // Don't idle-kill the focused Project — keep it warm for the next turn.
        if focusedProjectID == projectID {
            lock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now() + Self.idleTimeout)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            // Only tear down if still idle (not busy) and still unfocused.
            let session = self.sessions[projectID]
            let focused = self.focusedProjectID
            let busy = session?.isBusy ?? true
            self.lock.unlock()
            if !busy, focused != projectID {
                self.teardown(projectID: projectID)
            }
        }
        timer.resume()
        idleTimers[projectID] = timer
        lock.unlock()
    }

    private func cancelIdleTimer_locked(_ projectID: UUID) {
        idleTimers[projectID]?.cancel()
        idleTimers.removeValue(forKey: projectID)
    }

    // MARK: Executable resolution

    private func resolveClaudeExecutable() -> URL {
        if let claudeExecutableURL { return claudeExecutableURL }
        // Shared resolver: PATH + common installs (GUI apps often lack login PATH).
        if let url = ClaudeCLIPath.resolveClaudeExecutable() {
            return url
        }
        // Last resort: /usr/bin/env claude (may still fail if PATH is empty).
        return URL(fileURLWithPath: "/usr/bin/env")
    }
}

// MARK: - Single CLI process

/// Owns one `claude` subprocess and its stdio pipes for a single Project.
final class ClaudeCLISession: @unchecked Sendable {
    enum StartError: Error, Equatable {
        case executableMissing
        case spawnFailed(String)
        case resumeFailed
    }

    enum TurnOutcome: Equatable {
        case success
        case resumeFailed
    }

    let projectID: UUID
    let workingDirectory: String
    let systemPrompt: String
    let model: String?
    let effort: String?
    let resumeSessionID: String?
    let executableURL: URL
    /// When true, enable tools + bypass permission prompts (full Mac access).
    let fullMacAccess: Bool

    private let queue: DispatchQueue
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private var stdoutBuffer = Data()
    private var turnContinuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation?
    private var assembledText = ""
    private var usedAssistantSnapshots = false
    private var currentSessionID: String?
    private var currentModelLabel: String?
    private var turnFinished = false
    private var _isBusy = false
    private var _needsRehydrate = false
    private var turnWaiter: CheckedContinuation<TurnOutcome, Error>?
    private let stateLock = NSLock()
    /// Set during startup when stderr/stdout indicates a bad `--resume`.
    private var startupResumeFailed: Bool?
    /// Signaled when startup reaches a terminal state (init received, resume
    /// failed, or process died).
    private var startupGate: DispatchSemaphore?
    private var startupSettled = false
    /// Whether the most recently finished turn yielded `.completed`.
    private(set) var lastTurnSucceeded = false

    private(set) var isAlive: Bool = false

    var isBusy: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isBusy
    }

    var needsRehydrate: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _needsRehydrate
    }

    func markNeedsRehydrate() {
        stateLock.lock(); _needsRehydrate = true; stateLock.unlock()
    }

    func clearNeedsRehydrate() {
        stateLock.lock(); _needsRehydrate = false; stateLock.unlock()
    }

    init(
        projectID: UUID,
        workingDirectory: String,
        systemPrompt: String,
        model: String?,
        effort: String?,
        resumeSessionID: String?,
        executableURL: URL,
        queue: DispatchQueue,
        fullMacAccess: Bool = false
    ) {
        self.projectID = projectID
        self.workingDirectory = workingDirectory
        self.systemPrompt = systemPrompt
        self.model = model
        self.effort = effort
        self.resumeSessionID = resumeSessionID
        self.executableURL = executableURL
        self.queue = queue
        self.fullMacAccess = fullMacAccess
    }

    // MARK: Persistent start

    /// Spawn long-running process: `-p --input-format stream-json --output-format stream-json …`
    /// Stdin stays open for subsequent user messages.
    ///
    /// Blocks the caller until `system/init` arrives, the process dies
    /// (resume failure), or a short timeout elapses.
    func startPersistent() throws {
        let gate = DispatchSemaphore(value: 0)
        startupGate = gate
        startupSettled = false
        startupResumeFailed = nil

        try spawn(mode: .persistent)

        // Bad `--resume` exits in ~0.7s with "No conversation found"
        // (verified against CLI 2.1.212). Allow a few seconds for cold start.
        let result = gate.wait(timeout: .now() + 5.0)
        startupGate = nil

        if startupResumeFailed == true {
            teardownProcess()
            throw StartError.resumeFailed
        }
        if result == .timedOut {
            if process?.isRunning != true {
                throw StartError.spawnFailed("Claude process failed to start.")
            }
            // Still running without init — leave it; first turn surfaces errors.
            return
        }
        if currentSessionID == nil, process?.isRunning != true {
            if resumeSessionID != nil {
                teardownProcess()
                throw StartError.resumeFailed
            }
            throw StartError.spawnFailed("Claude process exited during startup.")
        }
    }

    /// Call from the I/O queue when startup reaches a decisive state.
    private func signalStartupIfNeeded() {
        guard !startupSettled else { return }
        let ready = currentSessionID != nil
            || startupResumeFailed == true
            || process?.isRunning == false
        guard ready else { return }
        startupSettled = true
        startupGate?.signal()
    }

    // MARK: Send turn on persistent process

    func sendUserMessage(
        _ text: String,
        continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation
    ) async throws -> TurnOutcome {
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<TurnOutcome, Error>) in
            queue.async {
                self.stateLock.lock()
                self._isBusy = true
                self.turnFinished = false
                self.lastTurnSucceeded = false
                self.assembledText = ""
                self.usedAssistantSnapshots = false
                self.turnContinuation = continuation
                self.turnWaiter = waiter
                self.stateLock.unlock()

                // system/init often arrives at process start, before any turn
                // is listening — re-emit so the chat UI can persist session_id.
                if let sid = self.currentSessionID {
                    continuation.yield(.sessionStarted(
                        sessionID: sid,
                        model: self.currentModelLabel,
                        capabilities: []
                    ))
                }

                guard self.isAlive, let stdin = self.stdinHandle else {
                    self.finishTurn(
                        outcome: .success,
                        error: ProviderError(category: .processDied, partialText: nil)
                    )
                    return
                }

                let payload: [String: Any] = [
                    "type": "user",
                    "message": [
                        "role": "user",
                        "content": text,
                    ],
                ]
                guard let data = try? JSONSerialization.data(withJSONObject: payload),
                      var line = String(data: data, encoding: .utf8)
                else {
                    self.finishTurn(
                        outcome: .success,
                        error: ProviderError(category: .unknown, message: "Failed to encode user message.")
                    )
                    return
                }
                line += "\n"
                if let bytes = line.data(using: .utf8) {
                    do {
                        try stdin.write(contentsOf: bytes)
                    } catch {
                        self.finishTurn(
                            outcome: .success,
                            error: ProviderError(
                                category: .processDied,
                                message: "Lost connection to Claude.",
                                partialText: self.assembledText.isEmpty ? nil : self.assembledText
                            )
                        )
                    }
                }
            }
        }
    }

    // MARK: One-shot spawn-per-turn

    func runOneShot(
        prompt: String,
        continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation
    ) async throws -> TurnOutcome {
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<TurnOutcome, Error>) in
            queue.async {
                self.stateLock.lock()
                self._isBusy = true
                self.turnFinished = false
                self.lastTurnSucceeded = false
                self.assembledText = ""
                self.usedAssistantSnapshots = false
                self.turnContinuation = continuation
                self.turnWaiter = waiter
                self.stateLock.unlock()

                do {
                    try self.spawn(mode: .oneShot(prompt: prompt))
                } catch let error as StartError where error == .resumeFailed {
                    self.finishTurn(outcome: .resumeFailed, error: nil)
                    return
                } catch {
                    self.finishTurn(
                        outcome: .success,
                        error: ProviderError(
                            category: .processDied,
                            message: (error as? LocalizedError)?.errorDescription ?? "\(error)"
                        )
                    )
                }
            }
        }
    }

    func cancelInFlight() {
        queue.async {
            // Best-effort: close stdin for one-shot; for persistent, send nothing
            // and mark the turn failed as processDied so partial is preserved.
            // Future: use interrupt capability (interrupt_receipt_v1) when we
            // confirm the control-message schema.
            let partial = self.assembledText
            self.finishTurn(
                outcome: .success,
                error: ProviderError(
                    category: .processDied,
                    message: "Stopped.",
                    partialText: partial.isEmpty ? nil : partial
                )
            )
            // Kill one-shot processes; keep persistent alive for the next turn.
            if let proc = self.process, self.stdinHandle == nil || !self.isPersistentMode {
                proc.terminate()
            }
        }
    }

    private var isPersistentMode = false

    func terminate() {
        queue.async {
            self.teardownProcess()
        }
        // Synchronously mark dead so callers don't reuse.
        isAlive = false
    }

    // MARK: Spawn

    private enum SpawnMode {
        case persistent
        case oneShot(prompt: String)
    }

    private func spawn(mode: SpawnMode) throws {
        // Ensure cwd exists — session lookup is cwd-scoped.
        try FileManager.default.createDirectory(
            atPath: workingDirectory,
            withIntermediateDirectories: true
        )

        let proc = Process()
        let args = buildArguments(mode: mode)

        if executableURL.lastPathComponent == "env" {
            proc.executableURL = executableURL
            proc.arguments = ["claude"] + args
        } else {
            proc.executableURL = executableURL
            proc.arguments = args
        }
        proc.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        // Max/Pro subscription path: expand PATH for GUI launches, use Claude
        // Code OAuth/keychain, and strip ANTHROPIC_API_KEY so we never silently
        // fall into pay-per-token Console billing (PLAN.md D5.1 — never --bare).
        proc.environment = ClaudeCLIPath.subscriptionEnvironment(
            base: ProcessInfo.processInfo.environment
        )

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        switch mode {
        case .persistent:
            isPersistentMode = true
            stdinHandle = stdinPipe.fileHandleForWriting
        case .oneShot:
            isPersistentMode = false
            // Write nothing further; -p takes the prompt as argv.
            stdinPipe.fileHandleForWriting.closeFile()
            stdinHandle = nil
        }

        var stderrData = Data()

        proc.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.queue.async {
                let status = process.terminationStatus
                let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
                if Self.looksLikeResumeFailure(stderrText) {
                    self.startupResumeFailed = true
                }

                self.isAlive = false
                self.stopReadSources()

                self.stateLock.lock()
                let busy = self._isBusy
                let partial = self.assembledText
                let finished = self.turnFinished
                self.stateLock.unlock()

                if busy && !finished {
                    if self.startupResumeFailed == true
                        || (
                            status != 0
                                && partial.isEmpty
                                && self.resumeSessionID != nil
                        )
                    {
                        self.finishTurn(outcome: .resumeFailed, error: nil)
                    } else {
                        self.finishTurn(
                            outcome: .success,
                            error: ProviderError(
                                category: .processDied,
                                message: "Lost connection to Claude.",
                                partialText: partial.isEmpty ? nil : partial
                            )
                        )
                    }
                } else if !busy, self.resumeSessionID != nil, status != 0 {
                    // Died during startup before any turn was sent.
                    self.startupResumeFailed = true
                }
                self.signalStartupIfNeeded()
            }
        }

        // Continuous stderr drain — an undrained stderr pipe deadlocks the child
        // once the buffer fills (PLAN.md hardening).
        let errHandle = stderrPipe.fileHandleForReading
        let errSource = DispatchSource.makeReadSource(fileDescriptor: errHandle.fileDescriptor, queue: queue)
        errSource.setEventHandler { [weak self] in
            let chunk = errHandle.availableData
            if chunk.isEmpty {
                // EOF
                return
            }
            stderrData.append(chunk)
            let text = String(data: chunk, encoding: .utf8) ?? ""
            if Self.looksLikeResumeFailure(text) {
                self?.startupResumeFailed = true
                self?.signalStartupIfNeeded()
            }
        }
        errSource.setCancelHandler {
            try? errHandle.close()
        }
        errSource.resume()
        stderrSource = errSource

        // Stdout NDJSON reader.
        let outHandle = stdoutPipe.fileHandleForReading
        let outSource = DispatchSource.makeReadSource(fileDescriptor: outHandle.fileDescriptor, queue: queue)
        outSource.setEventHandler { [weak self] in
            guard let self else { return }
            let chunk = outHandle.availableData
            if chunk.isEmpty {
                return
            }
            self.stdoutBuffer.append(chunk)
            self.drainStdoutLines()
        }
        outSource.setCancelHandler {
            try? outHandle.close()
        }
        outSource.resume()
        stdoutSource = outSource

        do {
            try proc.run()
        } catch {
            throw StartError.spawnFailed(error.localizedDescription)
        }
        process = proc
        isAlive = true
    }

    private func buildArguments(mode: SpawnMode) -> [String] {
        var args: [String] = []

        switch mode {
        case .persistent:
            // -p is required for --input-format/--output-format; with stream-json
            // input the process stays alive until stdin closes (multi-turn).
            args += [
                "-p",
                "--input-format", "stream-json",
                "--output-format", "stream-json",
                "--verbose",
                "--include-partial-messages",
            ]
        case .oneShot(let prompt):
            args += [
                "-p", prompt,
                "--output-format", "stream-json",
                "--verbose",
                "--include-partial-messages",
            ]
        }

        // System prompt always applied as full replace.
        args += ["--system-prompt", systemPrompt]

        let loadTools = fullMacAccess || ClaudeCLIProvider.isLoadToolsWhenNeededEnabled()
        if loadTools {
            // Tools available for this conversation.
            args += [
                "--tools", "default",
                "--setting-sources", "user",
            ]
            if fullMacAccess {
                // OpenClaw-style unrestricted: skip permission prompts, whole Mac.
                args += [
                    "--allow-dangerously-skip-permissions",
                    "--dangerously-skip-permissions",
                    "--permission-mode", "bypassPermissions",
                    "--add-dir", NSHomeDirectory(),
                ]
            } else {
                // Load tools when needed — tools on, still prompt for risky actions.
                args += [
                    "--permission-mode", "acceptEdits",
                ]
            }
            let skillsDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".prodigy/skills", isDirectory: true).path
            if FileManager.default.fileExists(atPath: skillsDir) {
                args += ["--add-dir", skillsDir]
            }
            if ClaudeCLIProvider.isConnectorSearchEnabled() {
                // Allow discovery of user skills/connectors directory.
                let claudeSkills = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".claude/skills", isDirectory: true).path
                if FileManager.default.fileExists(atPath: claudeSkills) {
                    args += ["--add-dir", claudeSkills]
                }
            }
        } else {
            // Chat-only — tools off, no global config/skills contamination.
            args += [
                "--tools", "",
                "--setting-sources", "",
                "--strict-mcp-config",
                "--disable-slash-commands",
            ]
        }

        // Raise transcript retention so resume survives longer (D5.3).
        // CLI accepts --settings as JSON string.
        let settingsJSON = #"{"cleanupPeriodDays":365}"#
        args += ["--settings", settingsJSON]

        if let model, !model.isEmpty {
            args += ["--model", model]
        }
        if let effort, !effort.isEmpty {
            args += ["--effort", effort]
        }
        if let resumeSessionID, !resumeSessionID.isEmpty {
            args += ["--resume", resumeSessionID]
        }

        // Hard ban on --bare — never append it.
        assert(!args.contains("--bare"), "--bare breaks subscription auth (PLAN.md D5.1)")
        return args
    }

    // MARK: Stdout drain

    private func drainStdoutLines() {
        while let range = stdoutBuffer.range(of: Data([0x0A])) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<range.lowerBound)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...range.lowerBound)
            if let line = String(data: lineData, encoding: .utf8) {
                handleLine(line)
            }
        }
    }

    private func handleLine(_ line: String) {
        let parsed = ClaudeCLIEventParser.parse(line: line)
        stateLock.lock()
        let cont = turnContinuation
        stateLock.unlock()

        switch parsed {
        case .ignore:
            break

        case .sessionInit(let sessionID, let model, let capabilities):
            currentSessionID = sessionID
            if let model { currentModelLabel = model }
            signalStartupIfNeeded()
            cont?.yield(.sessionStarted(
                sessionID: sessionID,
                model: model,
                capabilities: capabilities
            ))

        case .thinking:
            cont?.yield(.thinking)

        case .thinkingDelta(let text):
            cont?.yield(.thinkingDelta(text))

        case .textDelta(let text):
            assembledText += text
            cont?.yield(.textDelta(text))

        case .rateLimit(let utilization, let resetsAt, let status, let rateLimitType):
            cont?.yield(.rateLimitInfo(
                utilization: utilization,
                resetsAt: resetsAt,
                status: status,
                rateLimitType: rateLimitType
            ))

        case .apiRetry(let category, let message, let resetsAt):
            let partial = assembledText
            finishTurn(
                outcome: .success,
                error: ProviderError(
                    category: category,
                    message: message,
                    resetsAt: resetsAt,
                    partialText: partial.isEmpty ? nil : partial
                )
            )

        case .result(let text, let sessionID, let isError, let modelLabel, let usage):
            if let sessionID { currentSessionID = sessionID }
            if let modelLabel { currentModelLabel = modelLabel }
            let finalText = text.isEmpty ? assembledText : text
            if isError {
                // Resume-failure results often look like error_during_execution
                // with empty text while stderr says "No conversation found".
                if resumeSessionID != nil, assembledText.isEmpty {
                    startupResumeFailed = true
                    finishTurn(outcome: .resumeFailed, error: nil)
                    return
                }
                // Map generic result errors; finer categories come via api_retry.
                finishTurn(
                    outcome: .success,
                    error: ProviderError(
                        category: .unknown,
                        message: finalText.isEmpty ? "Claude returned an error." : finalText,
                        partialText: assembledText.isEmpty ? nil : assembledText
                    )
                )
            } else {
                cont?.yield(.completed(
                    text: finalText,
                    sessionID: currentSessionID,
                    modelLabel: currentModelLabel,
                    usage: usage
                ))
                lastTurnSucceeded = true
                finishTurn(outcome: .success, error: nil)
            }

        case .assistantTextSnapshot(let snapshot):
            // Prefer text_delta assembly; fall back to last full snapshot if no deltas.
            if assembledText.isEmpty {
                assembledText = snapshot
                usedAssistantSnapshots = true
                cont?.yield(.textDelta(snapshot))
            } else if usedAssistantSnapshots {
                // Replace with newer full snapshot.
                let previous = assembledText
                if snapshot.hasPrefix(previous) {
                    let delta = String(snapshot.dropFirst(previous.count))
                    if !delta.isEmpty {
                        assembledText = snapshot
                        cont?.yield(.textDelta(delta))
                    }
                } else {
                    assembledText = snapshot
                }
            }
        }
    }

    private func finishTurn(outcome: TurnOutcome, error: ProviderError?) {
        stateLock.lock()
        guard !turnFinished else {
            stateLock.unlock()
            return
        }
        turnFinished = true
        _isBusy = false
        if error != nil {
            lastTurnSucceeded = false
        }
        let waiter = turnWaiter
        turnWaiter = nil
        let cont = turnContinuation
        turnContinuation = nil
        stateLock.unlock()

        if let error {
            cont?.yield(.failed(error))
        }

        if let waiter {
            waiter.resume(returning: outcome)
        }

        // One-shot processes end with the turn — clean up.
        if !isPersistentMode {
            teardownProcess()
        }
    }

    private func stopReadSources() {
        stdoutSource?.cancel()
        stdoutSource = nil
        stderrSource?.cancel()
        stderrSource = nil
    }

    private func teardownProcess() {
        stopReadSources()
        if let stdin = stdinHandle {
            try? stdin.close()
            stdinHandle = nil
        }
        if let proc = process, proc.isRunning {
            proc.terminate()
            // Don't wait forever — process terminationHandler cleans state.
        }
        process = nil
        isAlive = false
        stateLock.lock()
        if _isBusy, !turnFinished {
            let partial = assembledText
            stateLock.unlock()
            finishTurn(
                outcome: .success,
                error: ProviderError(
                    category: .processDied,
                    partialText: partial.isEmpty ? nil : partial
                )
            )
        } else {
            stateLock.unlock()
        }
    }

    private static func looksLikeResumeFailure(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("no conversation found")
            || (lower.contains("session") && lower.contains("not found"))
            || lower.contains("could not find session")
    }
}

extension ClaudeCLIProvider {
    /// Thread-safe read of the full-Mac-access toggle (UserDefaults).
    nonisolated static func isFullMacAccessEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: AppStorageKey.fullMacAccess)
    }

    /// Default true when key unset — matches Settings UI default for "Load tools when needed".
    nonisolated static func isLoadToolsWhenNeededEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: AppStorageKey.loadToolsWhenNeeded) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: AppStorageKey.loadToolsWhenNeeded)
    }

    nonisolated static func isConnectorSearchEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: AppStorageKey.connectorSearch) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: AppStorageKey.connectorSearch)
    }
}

// MARK: - Convenience wiring for the app

extension ClaudeCLIProvider {
    /// Shared app-wide provider. Chat UI (Wave 3) and launch resume (T14)
    /// should use this instance so the LRU pool is global.
    static let shared: ClaudeCLIProvider = {
        let provider = ClaudeCLIProvider()
        provider.onBackgroundReplyCompleted = { projectID in
            // Post a notification so any ModelContext-aware observer can flip
            // `hasUnviewedActivity` without the provider importing SwiftData.
            NotificationCenter.default.post(
                name: .claudeCLIBackgroundReplyCompleted,
                object: nil,
                userInfo: ["projectID": projectID]
            )
        }
        return provider
    }()
}

extension Notification.Name {
    /// Posted when a background Project's turn completes successfully.
    /// `userInfo["projectID"]` is a `UUID`. WorkspaceRootView observes this
    /// to set `WorkspaceProject.hasUnviewedActivity` (green status-dot, T9).
    static let claudeCLIBackgroundReplyCompleted = Notification.Name(
        "com.commandcenter.claudeCLIBackgroundReplyCompleted"
    )
}

// MARK: - Request builders (for Wave 3 chat UI)

extension ModelTurnRequest {
    /// Build a turn request from a Project + thread + composer text.
    /// History excludes the just-typed user message (caller hasn't saved it
    /// yet, or should pass prior messages only).
    static func make(
        project: WorkspaceProject,
        thread: ChatThread,
        userMessage: String,
        systemPrompt: String = ClaudeCLIDefaults.generalAssistantSystemPrompt,
        model: String? = nil,
        effort: String? = nil,
        isBackground: Bool = false
    ) -> ModelTurnRequest {
        let history: [ModelHistoryMessage] = thread.sortedMessages.compactMap { msg in
            switch msg.role {
            case .user:
                return ModelHistoryMessage(role: .user, content: msg.content)
            case .assistant:
                return ModelHistoryMessage(role: .assistant, content: msg.content)
            case .system:
                return nil
            }
        }
        return ModelTurnRequest(
            projectID: project.id,
            threadID: thread.id,
            workingDirectory: project.folderPath,
            userMessage: userMessage,
            systemPrompt: systemPrompt,
            sessionID: thread.cliSessionID,
            history: history,
            model: model,
            effort: effort,
            isBackground: isBackground
        )
    }
}

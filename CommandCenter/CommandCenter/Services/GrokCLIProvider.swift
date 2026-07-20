import Foundation

// MARK: - GrokCLIProvider

/// Drives the installed `grok` CLI in headless mode for chat turns.
///
/// Uses `grok -p` + `--output-format streaming-json` (spawn-per-turn).
/// Auth is the user's grok.com OAuth (`grok login` → `~/.grok/auth.json`).
final class GrokCLIProvider: ModelProvider, @unchecked Sendable {
    var grokExecutableURL: URL?
    var forceSpawnPerTurn: Bool = true

    private let lock = NSLock()
    private var processes: [UUID: Process] = [:]
    private let ioQueue = DispatchQueue(label: "com.commandcenter.grok-cli", qos: .userInitiated)

    init(grokExecutableURL: URL? = nil) {
        self.grokExecutableURL = grokExecutableURL
    }

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
                self.cancelTurn(projectID: request.projectID)
            }
        }
    }

    func cancelTurn(projectID: UUID) {
        lock.lock()
        let proc = processes.removeValue(forKey: projectID)
        lock.unlock()
        proc?.terminate()
    }

    func setFocusedProject(_ projectID: UUID?) {
        // Spawn-per-turn — no warm process pool yet.
    }

    func teardown(projectID: UUID) {
        cancelTurn(projectID: projectID)
    }

    func teardownAll() {
        lock.lock()
        let all = Array(processes.values)
        processes.removeAll()
        lock.unlock()
        for p in all { p.terminate() }
    }

    // MARK: - Turn

    private func runTurn(
        _ request: ModelTurnRequest,
        continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation
    ) async throws {
        try FileManager.default.createDirectory(
            atPath: request.workingDirectory,
            withIntermediateDirectories: true
        )

        let executable = resolveGrokExecutable()
        let prompt = Self.buildPrompt(request: request)
        let args = buildArguments(request: request, prompt: prompt)

        let proc = Process()
        if executable.lastPathComponent == "env" {
            proc.executableURL = executable
            proc.arguments = ["grok"] + args
        } else {
            proc.executableURL = executable
            proc.arguments = args
        }
        proc.currentDirectoryURL = URL(fileURLWithPath: request.workingDirectory)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ClaudeCLIPath.augmentedPATH(env["PATH"])
        // Prefer OAuth session over accidental API-key-only mode when both exist
        // (CLI already prefers session; leave XAI_API_KEY if user set it).
        proc.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        proc.standardInput = FileHandle.nullDevice

        lock.lock()
        processes[request.projectID] = proc
        lock.unlock()

        var assembled = ""
        var reasoning = ""
        var sessionID: String?
        var modelLabel: String?
        var sawEnd = false

        do {
            try proc.run()
        } catch {
            lock.lock(); processes.removeValue(forKey: request.projectID); lock.unlock()
            let err = ProviderError(
                category: .processDied,
                message: "Could not start Grok: \(error.localizedDescription)"
            )
            continuation.yield(.failed(err))
            return
        }

        // Emit a sessionStarted once we have an ID (from end event); until then
        // yield thinking as soon as we see thought tokens.
        let outHandle = stdout.fileHandleForReading
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            ioQueue.async {
                defer { done.resume() }
                var buffer = Data()
                while true {
                    if Task.isCancelled {
                        proc.terminate()
                        break
                    }
                    let chunk = outHandle.availableData
                    if chunk.isEmpty {
                        break
                    }
                    buffer.append(chunk)
                    while let range = buffer.range(of: Data([0x0A])) {
                        let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                        buffer.removeSubrange(buffer.startIndex...range.lowerBound)
                        guard let line = String(data: lineData, encoding: .utf8) else { continue }
                        self.handleLine(
                            line,
                            assembled: &assembled,
                            reasoning: &reasoning,
                            sessionID: &sessionID,
                            modelLabel: &modelLabel,
                            sawEnd: &sawEnd,
                            continuation: continuation
                        )
                    }
                }
                proc.waitUntilExit()
            }
        }

        lock.lock()
        processes.removeValue(forKey: request.projectID)
        lock.unlock()

        if Task.isCancelled {
            continuation.yield(.failed(ProviderError(
                category: .processDied,
                message: "Stopped.",
                partialText: assembled.isEmpty ? nil : assembled
            )))
            return
        }

        if !sawEnd {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if proc.terminationStatus != 0 {
                let category: ProviderErrorCategory
                let lower = errText.lowercased()
                if lower.contains("auth") || lower.contains("login") || lower.contains("unauthorized") {
                    category = .authenticationFailed
                } else {
                    category = .processDied
                }
                continuation.yield(.failed(ProviderError(
                    category: category,
                    message: errText.isEmpty
                        ? "Grok exited without a reply (status \(proc.terminationStatus))."
                        : errText,
                    partialText: assembled.isEmpty ? nil : assembled
                )))
                return
            }
            // Success with only plain text and no end event — still complete.
            if !assembled.isEmpty {
                continuation.yield(.completed(
                    text: assembled,
                    sessionID: sessionID,
                    modelLabel: modelLabel ?? "grok"
                ))
                return
            }
            continuation.yield(.failed(ProviderError(
                category: .unknown,
                message: errText.isEmpty ? "Empty reply from Grok." : errText
            )))
        }
    }

    private func handleLine(
        _ line: String,
        assembled: inout String,
        reasoning: inout String,
        sessionID: inout String?,
        modelLabel: inout String?,
        sawEnd: inout Bool,
        continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation
    ) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return }

        switch type {
        case "thought":
            if let chunk = obj["data"] as? String, !chunk.isEmpty {
                if reasoning.isEmpty {
                    continuation.yield(.thinking)
                }
                reasoning += chunk
                continuation.yield(.thinkingDelta(chunk))
            } else {
                continuation.yield(.thinking)
            }

        case "text":
            if let chunk = obj["data"] as? String, !chunk.isEmpty {
                assembled += chunk
                continuation.yield(.textDelta(chunk))
            }

        case "end":
            sawEnd = true
            if let sid = obj["sessionId"] as? String ?? obj["session_id"] as? String {
                sessionID = sid
                continuation.yield(.sessionStarted(
                    sessionID: sid,
                    model: modelLabel,
                    capabilities: []
                ))
            }
            if let usage = obj["modelUsage"] as? [String: Any],
               let first = usage.keys.sorted().first {
                modelLabel = first
            }
            let text = assembled
            continuation.yield(.completed(
                text: text,
                sessionID: sessionID,
                modelLabel: modelLabel ?? "grok"
            ))

        case "error":
            let msg = (obj["message"] as? String)
                ?? (obj["data"] as? String)
                ?? "Grok error"
            let lower = msg.lowercased()
            let category: ProviderErrorCategory =
                (lower.contains("auth") || lower.contains("login"))
                ? .authenticationFailed : .unknown
            continuation.yield(.failed(ProviderError(
                category: category,
                message: msg,
                partialText: assembled.isEmpty ? nil : assembled
            )))
            sawEnd = true

        default:
            break
        }
    }

    // MARK: - Prompt / args

    static func buildPrompt(request: ModelTurnRequest) -> String {
        guard !request.history.isEmpty else {
            return request.userMessage
        }
        var parts: [String] = [
            "Prior conversation (continue naturally from the latest user message):",
            "---",
            "",
        ]
        for msg in request.history {
            let label = msg.role == .user ? "User" : "Assistant"
            parts.append("\(label): \(msg.content)")
            parts.append("")
        }
        parts.append("User: \(request.userMessage)")
        return parts.joined(separator: "\n")
    }

    private func buildArguments(request: ModelTurnRequest, prompt: String) -> [String] {
        let fullAccess = UserDefaults.standard.bool(forKey: AppStorageKey.fullMacAccess)
        let loadTools: Bool = {
            if fullAccess { return true }
            if UserDefaults.standard.object(forKey: AppStorageKey.loadToolsWhenNeeded) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: AppStorageKey.loadToolsWhenNeeded)
        }()
        var args: [String] = [
            "-p", prompt,
            "--output-format", "streaming-json",
            "--verbatim",
            "--system-prompt-override", request.systemPrompt,
        ]
        if fullAccess {
            // OpenClaw-style: all tools, auto-approve, web enabled.
            args += [
                "--permission-mode", "bypassPermissions",
            ]
        } else if loadTools {
            // Tools when needed — allow tools with edit auto-accept, keep web.
            args += [
                "--permission-mode", "acceptEdits",
            ]
        } else {
            // Restricted chat: no terminal/write/search tools.
            args += [
                "--disable-web-search",
                "--disallowed-tools",
                "run_terminal_cmd,search_replace,write,web_search,web_fetch,Agent",
                "--permission-mode", "dontAsk",
            ]
        }
        if let model = request.model, !model.isEmpty {
            args += ["--model", model]
        }
        if let effort = request.effort, !effort.isEmpty {
            // Map Claude "xhigh" if needed; grok accepts xhigh/max.
            args += ["--effort", effort]
        }
        return args
    }

    private func resolveGrokExecutable() -> URL {
        if let grokExecutableURL { return grokExecutableURL }
        if let url = GrokCLIPath.resolveGrokExecutable() {
            return url
        }
        return URL(fileURLWithPath: "/usr/bin/env")
    }
}

// MARK: - Path helpers

enum GrokCLIPath {
    static func resolveGrokExecutable() -> URL? {
        if let path = which("grok") {
            return URL(fileURLWithPath: path)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.grok/bin/grok",
            "\(home)/.local/bin/grok",
            "/usr/local/bin/grok",
            "/opt/homebrew/bin/grok",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        return nil
    }

    private static func which(_ name: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = [name]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ClaudeCLIPath.augmentedPATH(env["PATH"])
        // Prefer ~/.grok/bin first for the real grok CLI.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.grok/bin:" + (env["PATH"] ?? "")
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty == false) ? path : nil
    }
}

extension GrokCLIProvider {
    static let shared = GrokCLIProvider()
}

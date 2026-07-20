import AppKit
import Foundation

// MARK: - Claude subscription auth (Claude Max / Pro via Claude Code CLI)

/// Snapshot of `claude auth status` — the supported way Prodigy uses a
/// Claude Max (or Pro) subscription. Login is Claude Code OAuth (`claude.ai`),
/// never an Anthropic Console API key.
struct ClaudeAuthSnapshot: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case idle
        case checking
        case cliMissing
        case loggedOut
        case loggedIn(ClaudeSubscriptionAccount)
        case probeFailed(String)
    }

    var state: State = .idle
    /// Absolute path to the `claude` binary when found.
    var executablePath: String?
    /// True when the process environment has `ANTHROPIC_API_KEY` (would force
    /// pay-per-token API billing instead of Max/Pro subscription).
    var hasAPIKeyInEnvironment: Bool = false

    var isLoggedIn: Bool {
        if case .loggedIn = state { return true }
        return false
    }

    var isMax: Bool {
        if case .loggedIn(let account) = state { return account.isMax }
        return false
    }
}

struct ClaudeSubscriptionAccount: Equatable, Sendable {
    let email: String?
    /// CLI `subscriptionType`: "max", "pro", "team", …
    let subscriptionType: String?
    let authMethod: String?
    let apiProvider: String?
    let orgName: String?

    var isMax: Bool {
        subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "max"
    }

    /// Human plan label for Settings: "Claude Max", "Claude Pro", …
    var planDisplayName: String {
        let raw = subscriptionType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case "max": return "Claude Max"
        case "pro": return "Claude Pro"
        case "team": return "Claude Team"
        case "enterprise": return "Claude Enterprise"
        case "free", "": return "Claude (free)"
        case .some(let other): return "Claude \(other.capitalized)"
        case .none: return "Claude subscription"
        }
    }

    var statusLine: String {
        if let email, !email.isEmpty {
            return "\(planDisplayName) · \(email)"
        }
        return planDisplayName
    }
}

// MARK: - Service

/// Probes Claude Code login and launches Max/Pro subscription sign-in.
///
/// Prodigy never implements its own OAuth — it uses the installed Claude Code
/// CLI (`claude auth status` / `claude auth login --claudeai`), which is the
/// Anthropic-supported surface for Max and Pro plans.
@MainActor
@Observable
final class ClaudeAuthService {
    static let shared = ClaudeAuthService()

    private(set) var snapshot = ClaudeAuthSnapshot()

    /// Refresh `claude auth status --json` on a background queue.
    func refresh() async {
        snapshot.state = .checking
        let result = await Task.detached(priority: .userInitiated) {
            Self.probe()
        }.value
        snapshot = result
    }

    /// Open Terminal and run `claude auth login --claudeai` so the user signs
    /// in with the same Claude.ai account that carries Max/Pro.
    @discardableResult
    func openClaudeAILogin() -> Bool {
        let executable = snapshot.executablePath
            ?? ClaudeCLIPath.resolveClaudeExecutable()?.path
            ?? "claude"
        // Quote path for shells; --claudeai forces subscription (not Console API).
        let command = "\(Self.shellQuote(executable)) auth login --claudeai"
        return Self.runInTerminal(command)
    }

    /// Open Terminal with a short status check the user can re-run.
    @discardableResult
    func openAuthStatusInTerminal() -> Bool {
        let executable = snapshot.executablePath
            ?? ClaudeCLIPath.resolveClaudeExecutable()?.path
            ?? "claude"
        let command = "\(Self.shellQuote(executable)) auth status --text"
        return Self.runInTerminal(command)
    }

    // MARK: Probe (off main actor)

    nonisolated private static func probe() -> ClaudeAuthSnapshot {
        var snap = ClaudeAuthSnapshot()
        snap.hasAPIKeyInEnvironment = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
            .map { !$0.isEmpty } ?? false

        guard let exe = ClaudeCLIPath.resolveClaudeExecutable() else {
            snap.state = .cliMissing
            return snap
        }
        snap.executablePath = exe.path

        let proc = Process()
        proc.executableURL = exe
        proc.arguments = ["auth", "status", "--json"]
        // Auth status should not need network for cached credentials; keep env clean.
        proc.environment = ClaudeCLIPath.subscriptionEnvironment(
            base: ProcessInfo.processInfo.environment
        )
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            snap.state = .probeFailed(error.localizedDescription)
            return snap
        }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errText = String(
            data: err.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        guard !data.isEmpty else {
            if proc.terminationStatus != 0 {
                // Not logged in often exits non-zero with empty/minimal stdout.
                snap.state = .loggedOut
            } else {
                snap.state = .probeFailed(
                    errText.isEmpty ? "Empty response from claude auth status." : errText
                )
            }
            return snap
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Fallback: treat non-JSON success as logged out / unknown.
            let text = String(data: data, encoding: .utf8) ?? ""
            if text.lowercased().contains("not logged") || proc.terminationStatus != 0 {
                snap.state = .loggedOut
            } else {
                snap.state = .probeFailed("Could not parse claude auth status.")
            }
            return snap
        }

        let loggedIn = (json["loggedIn"] as? Bool) ?? false
        if !loggedIn {
            snap.state = .loggedOut
            return snap
        }

        let account = ClaudeSubscriptionAccount(
            email: json["email"] as? String,
            subscriptionType: json["subscriptionType"] as? String,
            authMethod: json["authMethod"] as? String,
            apiProvider: json["apiProvider"] as? String,
            orgName: json["orgName"] as? String
        )
        snap.state = .loggedIn(account)
        return snap
    }

    // MARK: Terminal launch

    nonisolated private static func runInTerminal(_ command: String) -> Bool {
        // AppleScript: open a new Terminal window running the login/status command.
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", source]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    nonisolated private static func shellQuote(_ path: String) -> String {
        // Single-quote for zsh/bash; escape embedded single quotes.
        if path.contains("'") {
            let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
            return "'\(escaped)'"
        }
        return "'\(path)'"
    }
}

// MARK: - Shared CLI path / env helpers

/// Shared resolution for the `claude` binary and subscription-safe environment.
/// Used by `ClaudeCLIProvider` (chat) and `ClaudeAuthService` (status/login).
enum ClaudeCLIPath {
    /// Locate the installed Claude Code CLI. Prefer PATH, then common installs.
    static func resolveClaudeExecutable() -> URL? {
        if let path = which("claude") {
            return URL(fileURLWithPath: path)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        return nil
    }

    /// PATH suitable for GUI-spawned processes (login shell bins often missing).
    static func augmentedPATH(_ existing: String?) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extras = [
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        var parts: [String] = []
        var seen = Set<String>()
        for p in extras + (existing ?? "").split(separator: ":").map(String.init) {
            guard !p.isEmpty, !seen.contains(p) else { continue }
            seen.insert(p)
            parts.append(p)
        }
        return parts.joined(separator: ":")
    }

    /// Environment for Claude Code CLI when using Max/Pro subscription auth.
    ///
    /// - Expands PATH so AppKit-launched processes find `claude`.
    /// - Strips `ANTHROPIC_API_KEY` so the CLI uses OAuth/keychain (Max/Pro)
    ///   instead of pay-per-token Console billing.
    /// - Clears `CLAUDE_CODE_SIMPLE` / never forces bare mode.
    static func subscriptionEnvironment(base: [String: String]) -> [String: String] {
        var env = base
        env["PATH"] = augmentedPATH(env["PATH"])
        // API key forces token billing and bypasses Claude Max/Pro subscription.
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        env.removeValue(forKey: "CLAUDE_CODE_SIMPLE")
        return env
    }

    private static func which(_ name: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = [name]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = augmentedPATH(env["PATH"])
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

import AppKit
import Foundation

// MARK: - Grok / xAI auth (grok.com OAuth via grok CLI)

struct GrokAuthSnapshot: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case idle
        case checking
        case cliMissing
        case loggedOut
        case loggedIn(email: String?, authMode: String?)
        case probeFailed(String)
    }

    var state: State = .idle
    var executablePath: String?
    var hasAPIKeyInEnvironment: Bool = false

    var isLoggedIn: Bool {
        if case .loggedIn = state { return true }
        return false
    }
}

/// Probes `~/.grok/auth.json` and launches `grok login` for subscription auth.
@MainActor
@Observable
final class GrokAuthService {
    static let shared = GrokAuthService()

    private(set) var snapshot = GrokAuthSnapshot()

    func refresh() async {
        snapshot.state = .checking
        let result = await Task.detached(priority: .userInitiated) {
            Self.probe()
        }.value
        snapshot = result
    }

    @discardableResult
    func openLogin() -> Bool {
        let executable = snapshot.executablePath
            ?? GrokCLIPath.resolveGrokExecutable()?.path
            ?? "grok"
        let quoted = Self.shellQuote(executable)
        return Self.runInTerminal("\(quoted) login --oauth")
    }

    @discardableResult
    func openLogout() -> Bool {
        let executable = snapshot.executablePath
            ?? GrokCLIPath.resolveGrokExecutable()?.path
            ?? "grok"
        let quoted = Self.shellQuote(executable)
        return Self.runInTerminal("\(quoted) logout")
    }

    // MARK: Probe

    nonisolated private static func probe() -> GrokAuthSnapshot {
        var snap = GrokAuthSnapshot()
        snap.hasAPIKeyInEnvironment =
            ProcessInfo.processInfo.environment["XAI_API_KEY"].map { !$0.isEmpty } ?? false

        guard let exe = GrokCLIPath.resolveGrokExecutable() else {
            snap.state = .cliMissing
            return snap
        }
        snap.executablePath = exe.path

        // Primary: parse ~/.grok/auth.json (OAuth session).
        let authURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/auth.json")
        if let data = try? Data(contentsOf: authURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           !obj.isEmpty {
            // Structure: { "https://auth.x.ai::clientId": { email, auth_mode, ... } }
            var email: String?
            var mode: String?
            for (_, value) in obj {
                guard let entry = value as? [String: Any] else { continue }
                email = entry["email"] as? String
                mode = entry["auth_mode"] as? String
                if email != nil { break }
            }
            if email != nil || obj.values.contains(where: { ($0 as? [String: Any])?["refresh_token"] != nil }) {
                snap.state = .loggedIn(email: email, authMode: mode ?? "oauth")
                return snap
            }
        }

        // Fallback: API key only
        if snap.hasAPIKeyInEnvironment {
            snap.state = .loggedIn(email: nil, authMode: "api_key")
            return snap
        }

        snap.state = .loggedOut
        return snap
    }

    nonisolated private static func runInTerminal(_ command: String) -> Bool {
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
        if path.contains("'") {
            let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
            return "'\(escaped)'"
        }
        return "'\(path)'"
    }
}

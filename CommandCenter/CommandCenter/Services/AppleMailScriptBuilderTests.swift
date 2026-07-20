import Foundation

#if DEBUG
/// Lightweight regression checks for AppleMailScriptBuilder.
/// Run from app DEBUG launch or via `AppleMailScriptBuilder.runRegressionTests()`.
///
/// Covers:
/// - Forbidden `(read status…)` form that produced -2741 “found rd”
/// - String literal escaping for spaces, apostrophe, double-quote, reserved words
/// - osascript compile of static templates with argv (no user-string injection)
enum AppleMailScriptBuilderTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    @discardableResult
    static func runRegressionTests() throws -> String {
        var log: [String] = []

        // 1) Validator rejects the historical footgun.
        let bad = #"set rdVal to (read status of m) as text"#
        do {
            try AppleMailScriptBuilder.validateScriptSource(bad)
            throw Failure(description: "expected validateScriptSource to reject (read status")
        } catch AppleMailError.scriptGenerationFailed(let value, _) {
            log.append("OK reject forbidden form: \(value)")
        }

        let badVar = #"set rd to true"#
        do {
            try AppleMailScriptBuilder.validateScriptSource(badVar)
            throw Failure(description: "expected validateScriptSource to reject set rd to")
        } catch AppleMailError.scriptGenerationFailed {
            log.append("OK reject banned variable rd")
        }

        // 2) Escaping for nasty mailbox/account-like strings.
        let samples = [
            "Work Mail",
            "O'Brien Inbox",
            "Say \"Hello\"",
            "record third forward", // reserved-ish words
            "path\\with\\backslash",
            "line1\nline2",
        ]
        for s in samples {
            let lit = AppleMailScriptBuilder.appleScriptStringLiteral(s)
            // Must be a quoted literal and not contain raw unescaped " inside (except via \").
            guard lit.hasPrefix("\""), lit.hasSuffix("\"") else {
                throw Failure(description: "literal not quoted for \(s)")
            }
            // Compile a tiny script that only binds the literal — proves escaping.
            let script = """
            on run
              set x to \(lit)
              return x
            end run
            """
            let out = try compileAndRun(script, arguments: [])
            // AppleScript may normalize line endings when round-tripping.
            let normalizedOut = out.trimmingCharacters(in: .newlines)
            let normalizedIn = s.replacingOccurrences(of: "\n", with: "\n")
            if normalizedOut != normalizedIn && normalizedOut != s.replacingOccurrences(of: "\n", with: "\r") {
                // Allow return vs linefeed from AppleScript string rebuild.
                let strippedOut = normalizedOut.replacingOccurrences(of: "\r", with: "\n")
                let strippedIn = normalizedIn.replacingOccurrences(of: "\r", with: "\n")
                if strippedOut != strippedIn {
                    throw Failure(description: "round-trip mismatch for \(s.debugDescription): got \(out.debugDescription)")
                }
            }
            log.append("OK escape/compile: \(s.debugDescription)")
        }

        // 3) Real templates compile (osascript -c style via file) with argv.
        for (name, source, args) in [
            ("folders", AppleMailScriptBuilder.listFoldersScript(), [] as [String]),
            ("folder-msgs", AppleMailScriptBuilder.folderMessagesScript(), ["Exchange", "Inbox", "5"]),
            ("detail", AppleMailScriptBuilder.messageDetailScript(), ["Exchange", "Inbox", "1"]),
            ("reveal", AppleMailScriptBuilder.revealScript(), ["Exchange", "Inbox", "1"]),
            ("launch", AppleMailScriptBuilder.launchMailScript(), [] as [String]),
        ] as [(String, String, [String])] {
            try AppleMailScriptBuilder.validateScriptSource(source)
            // Compile only: run may fail without Mail permission; we only need
            // successful *compilation*. osascript returns syntax errors on compile.
            try compileOnly(source, label: name)
            // Also ensure argv form is accepted by running with dry args.
            // launch has no argv; detail/reveal may fail at runtime if no such message —
            // that's OK as long as it's not a syntax error.
            do {
                _ = try compileAndRun(source, arguments: args)
                log.append("OK compile+run \(name)")
            } catch {
                let msg = "\(error)"
                if msg.lowercased().contains("syntax") || msg.contains("-2741") || msg.contains("found \"rd\"") {
                    throw Failure(description: "template \(name) syntax/compile failure: \(msg)")
                }
                log.append("OK compile \(name) (runtime: \(msg.prefix(80)))")
            }
        }

        // 4) Embedding a reserved-word “account name” via literal in a synthetic script.
        let account = "record \"third\" O'Brien forward"
        let lit = AppleMailScriptBuilder.appleScriptStringLiteral(account)
        let synthetic = """
        on run
          set accountName to \(lit)
          if accountName is \"\" then error \"empty\"
          return accountName
        end run
        """
        let round = try compileAndRun(synthetic, arguments: [])
        if !round.contains("O'Brien") {
            throw Failure(description: "synthetic account literal failed: \(round)")
        }
        log.append("OK reserved-word account name literal")

        return log.joined(separator: "\n")
    }

    private static func compileOnly(_ source: String, label: String) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prodigy-mail-test-\(label).scpt.txt")
        try source.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        // osascript compiles then runs; with `return` only scripts that's fine.
        // For `on run argv` scripts, provide a dummy arg so execution starts after compile.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [url.path, "1"]
        let err = Pipe()
        let out = Pipe()
        process.standardError = err
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if stderr.lowercased().contains("syntax") || stderr.contains("-2741") {
            throw Failure(description: "compileOnly \(label): \(stderr)")
        }
    }

    private static func compileAndRun(_ source: String, arguments: [String]) throws -> String {
        try AppleMailScriptBuilder.validateScriptSource(source)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prodigy-mail-test-\(UUID().uuidString).scpt.txt")
        try source.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [url.path] + arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw Failure(description: stderr.isEmpty ? "exit \(process.terminationStatus)" : stderr)
        }
        return stdout
    }
}
#endif

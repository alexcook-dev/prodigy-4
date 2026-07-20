import Foundation

// MARK: - Stream-JSON line parser

/// Parses one NDJSON line from the Claude CLI `--output-format stream-json`
/// pipe. Confined here so version drift in event shapes breaks one file
/// (PLAN.md hardening note).
enum ClaudeCLIEventParser {
    /// Result of parsing a single stdout line.
    enum Parsed: Equatable {
        case ignore
        case sessionInit(sessionID: String, model: String?, capabilities: [String])
        case thinking
        case thinkingDelta(String)
        case textDelta(String)
        case rateLimit(
            utilization: Double?,
            resetsAt: Date?,
            status: String?,
            rateLimitType: String?
        )
        case apiRetry(category: ProviderErrorCategory, message: String?, resetsAt: Date?)
        case result(
            text: String,
            sessionID: String?,
            isError: Bool,
            modelLabel: String?,
            usage: TurnUsageMetrics?
        )
        case assistantTextSnapshot(String)
    }

    static func parse(line: String) -> Parsed {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .ignore
        }

        let type = obj["type"] as? String

        switch type {
        case "system":
            return parseSystem(obj)
        case "stream_event":
            return parseStreamEvent(obj)
        case "rate_limit_event":
            return parseRateLimit(obj)
        case "result":
            return parseResult(obj)
        case "assistant":
            return parseAssistant(obj)
        default:
            return .ignore
        }
    }

    // MARK: system

    private static func parseSystem(_ obj: [String: Any]) -> Parsed {
        let subtype = obj["subtype"] as? String
        switch subtype {
        case "init":
            let sessionID = (obj["session_id"] as? String) ?? ""
            let model = obj["model"] as? String
            let caps = (obj["capabilities"] as? [String]) ?? []
            guard !sessionID.isEmpty else { return .ignore }
            return .sessionInit(sessionID: sessionID, model: model, capabilities: caps)

        case "api_retry":
            // Typed categories: authentication_failed, billing_error, rate_limit, overloaded, …
            let categoryRaw =
                (obj["error_category"] as? String)
                ?? (obj["category"] as? String)
                ?? (obj["error"] as? [String: Any]).flatMap { $0["type"] as? String }
                ?? (obj["error"] as? String)
            let category = ProviderErrorCategory.fromCLICategory(categoryRaw)
            let message =
                (obj["message"] as? String)
                ?? (obj["error"] as? [String: Any]).flatMap { $0["message"] as? String }
            let resetsAt = parseTimestamp(
                obj["resetsAt"] ?? obj["resets_at"]
                    ?? (obj["rate_limit_info"] as? [String: Any])?["resetsAt"]
            )
            return .apiRetry(category: category, message: message, resetsAt: resetsAt)

        case "status":
            // requesting / etc. — not surfaced as stream events for V1
            return .ignore

        case "thinking_tokens":
            return .thinking

        default:
            return .ignore
        }
    }

    // MARK: stream_event

    private static func parseStreamEvent(_ obj: [String: Any]) -> Parsed {
        guard let event = obj["event"] as? [String: Any] else { return .ignore }
        let eventType = event["type"] as? String

        switch eventType {
        case "content_block_start":
            if let block = event["content_block"] as? [String: Any] {
                let blockType = block["type"] as? String
                if blockType == "thinking" {
                    // Some payloads include initial thinking text on start.
                    if let thinking = block["thinking"] as? String, !thinking.isEmpty {
                        return .thinkingDelta(thinking)
                    }
                    return .thinking
                }
                // Tool / code invocations — surface in the reasoning panel.
                if blockType == "tool_use" || blockType == "server_tool_use" {
                    let name = (block["name"] as? String) ?? "tool"
                    var line = "▸ \(name)"
                    if let input = block["input"] {
                        if let data = try? JSONSerialization.data(
                            withJSONObject: input,
                            options: [.sortedKeys]
                        ), let json = String(data: data, encoding: .utf8) {
                            line += "\n\(json)"
                        }
                    }
                    return .thinkingDelta(line + "\n")
                }
            }
            return .ignore

        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any] else { return .ignore }
            let deltaType = delta["type"] as? String
            if deltaType == "text_delta", let text = delta["text"] as? String, !text.isEmpty {
                return .textDelta(text)
            }
            // Extended thinking / reasoning tokens (shown via UI toggle).
            if deltaType == "thinking_delta" {
                let text = (delta["thinking"] as? String)
                    ?? (delta["text"] as? String)
                    ?? ""
                if !text.isEmpty { return .thinkingDelta(text) }
                return .thinking
            }
            // Partial tool input JSON
            if deltaType == "input_json_delta",
               let partial = delta["partial_json"] as? String,
               !partial.isEmpty {
                return .thinkingDelta(partial)
            }
            return .ignore

        default:
            return .ignore
        }
    }

    // MARK: rate_limit_event

    private static func parseRateLimit(_ obj: [String: Any]) -> Parsed {
        let info = obj["rate_limit_info"] as? [String: Any] ?? obj
        let utilization =
            (info["utilization"] as? Double)
            ?? (info["utilization"] as? Int).map(Double.init)
        let status = info["status"] as? String
        let resetsAt = parseTimestamp(
            info["resetsAt"] ?? info["resets_at"] ?? info["resetAt"]
        )
        let rateLimitType =
            (info["rateLimitType"] as? String)
            ?? (info["rate_limit_type"] as? String)
            ?? (obj["rateLimitType"] as? String)
        return .rateLimit(
            utilization: utilization,
            resetsAt: resetsAt,
            status: status,
            rateLimitType: rateLimitType
        )
    }

    // MARK: result

    private static func parseResult(_ obj: [String: Any]) -> Parsed {
        let text = (obj["result"] as? String) ?? ""
        let sessionID = obj["session_id"] as? String
        let isError = (obj["is_error"] as? Bool) ?? false
        // Prefer modelUsage keys; fall back to nothing — session init already carried model.
        var modelLabel: String?
        var usageMetrics: TurnUsageMetrics?
        if let usage = obj["modelUsage"] as? [String: Any] {
            // Pick the non-haiku helper model if present, else first key.
            let keys = usage.keys.sorted()
            modelLabel = keys.first { !$0.contains("haiku") } ?? keys.first
            usageMetrics = sumModelUsage(usage)
        }
        // Top-level usage object (some CLI builds).
        if usageMetrics == nil || usageMetrics?.isEmpty == true {
            if let top = obj["usage"] as? [String: Any] {
                let input = intValue(top["input_tokens"] ?? top["inputTokens"])
                let output = intValue(top["output_tokens"] ?? top["outputTokens"])
                if input + output > 0 {
                    usageMetrics = TurnUsageMetrics(inputTokens: input, outputTokens: output)
                }
            }
        }
        return .result(
            text: text,
            sessionID: sessionID,
            isError: isError,
            modelLabel: modelLabel,
            usage: usageMetrics
        )
    }

    private static func sumModelUsage(_ usage: [String: Any]) -> TurnUsageMetrics {
        var input = 0
        var output = 0
        for (_, value) in usage {
            guard let block = value as? [String: Any] else { continue }
            input += intValue(
                block["inputTokens"] ?? block["input_tokens"] ?? block["inputTokenCount"]
            )
            output += intValue(
                block["outputTokens"] ?? block["output_tokens"] ?? block["outputTokenCount"]
            )
        }
        return TurnUsageMetrics(inputTokens: input, outputTokens: output)
    }

    private static func intValue(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String, let i = Int(s) { return i }
        return 0
    }

    // MARK: assistant (full message snapshots — useful if partials are off)

    private static func parseAssistant(_ obj: [String: Any]) -> Parsed {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return .ignore }

        var texts: [String] = []
        for block in content {
            if (block["type"] as? String) == "text", let t = block["text"] as? String {
                texts.append(t)
            }
        }
        let joined = texts.joined()
        return joined.isEmpty ? .ignore : .assistantTextSnapshot(joined)
    }

    // MARK: helpers

    /// Accepts unix seconds (Int/Double) or ISO-ish strings.
    private static func parseTimestamp(_ value: Any?) -> Date? {
        if let n = value as? TimeInterval {
            // Heuristic: ms vs s
            return Date(timeIntervalSince1970: n > 1_000_000_000_000 ? n / 1000 : n)
        }
        if let n = value as? Int {
            let d = Double(n)
            return Date(timeIntervalSince1970: d > 1_000_000_000_000 ? d / 1000 : d)
        }
        if let s = value as? String, let d = Double(s) {
            return Date(timeIntervalSince1970: d > 1_000_000_000_000 ? d / 1000 : d)
        }
        return nil
    }
}

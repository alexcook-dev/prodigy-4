import Foundation
import SwiftData

/// Persistent AI persona (saved system prompt). Shared across every Project;
/// conversation history with an Agent is scoped per-Project via `ChatThread`.
///
/// V1: synchronous persona-flavored chat only — not an autonomous worker.
@Model
final class Agent {
    var id: UUID
    var name: String
    /// Full system-prompt body used with `--system-prompt` replace (never append).
    var systemPrompt: String
    var hasUnviewedActivity: Bool
    var createdAt: Date
    var lastActiveAt: Date

    @Relationship(deleteRule: .nullify, inverse: \ChatThread.agent)
    var threads: [ChatThread] = []

    init(
        name: String,
        systemPrompt: String,
        hasUnviewedActivity: Bool = false,
        createdAt: Date = .now,
        lastActiveAt: Date = .now
    ) {
        self.id = UUID()
        self.name = name
        self.systemPrompt = systemPrompt
        self.hasUnviewedActivity = hasUnviewedActivity
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
    }
}

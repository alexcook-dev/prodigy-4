import Foundation
import SwiftData

/// A conversation thread. PLAN.md calls this "Thread"; the type is `ChatThread`
/// to avoid colliding with Foundation's `Thread`.
///
/// Multiple general (agent-less) threads per Project are allowed — each can be
/// an open center-pane chat tab. Agent conversations are separate threads
/// scoped to (Project, Agent).
@Model
final class ChatThread {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    /// Claude CLI session id for `--resume` (cache; SwiftData is durable store).
    var cliSessionID: String?

    var project: WorkspaceProject?
    var agent: Agent?

    @Relationship(deleteRule: .cascade, inverse: \Message.thread)
    var messages: [Message] = []

    init(
        title: String = "Chat",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        cliSessionID: String? = nil,
        project: WorkspaceProject? = nil,
        agent: Agent? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.cliSessionID = cliSessionID
        self.project = project
        self.agent = agent
    }

    var sortedMessages: [Message] {
        messages.sorted { $0.createdAt < $1.createdAt }
    }
}

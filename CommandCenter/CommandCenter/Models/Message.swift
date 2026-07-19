import Foundation
import SwiftData

enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}

/// One turn (or partial turn) inside a `ChatThread`.
@Model
final class Message {
    var id: UUID
    var roleRaw: String
    var content: String
    var createdAt: Date
    /// Truncated mid-stream replies kept and tagged "[partial — kept]" (T13).
    var isPartial: Bool
    /// Provider model label for assistant messages (display only until T5).
    var modelLabel: String?

    var thread: ChatThread?

    var role: MessageRole {
        get { MessageRole(rawValue: roleRaw) ?? .user }
        set { roleRaw = newValue.rawValue }
    }

    init(
        role: MessageRole,
        content: String,
        createdAt: Date = .now,
        isPartial: Bool = false,
        modelLabel: String? = nil,
        thread: ChatThread? = nil
    ) {
        self.id = UUID()
        self.roleRaw = role.rawValue
        self.content = content
        self.createdAt = createdAt
        self.isPartial = isPartial
        self.modelLabel = modelLabel
        self.thread = thread
    }
}

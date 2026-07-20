import Foundation

/// App-wide access policy for LLM turns (chat-safe vs full Mac agent).
///
/// When **full Mac access** is on (OpenClaw-style), Prodigy spawns Claude/Grok
/// with tools enabled and permission checks bypassed so the model can use the
/// terminal, edit files, and reach the whole machine from the project cwd.
///
/// Default is **off** — plain chat with tools disabled (PLAN.md D5.1).
@MainActor
final class ProdigyAccessSettings: ObservableObject {
    static let shared = ProdigyAccessSettings()

    /// UserDefaults key — also used via `@AppStorage` in Settings.
    static let fullMacAccessKey = AppStorageKey.fullMacAccess

    @Published private(set) var fullMacAccess: Bool {
        didSet {
            guard fullMacAccess != oldValue else { return }
            UserDefaults.standard.set(fullMacAccess, forKey: Self.fullMacAccessKey)
            NotificationCenter.default.post(name: .prodigyAccessModeDidChange, object: fullMacAccess)
        }
    }

    private init() {
        fullMacAccess = UserDefaults.standard.bool(forKey: Self.fullMacAccessKey)
    }

    func setFullMacAccess(_ enabled: Bool) {
        fullMacAccess = enabled
    }

    /// System prompt when full Mac access is on (coding/agent posture).
    static let fullAccessSystemPrompt = """
    You are Prodigy, a capable personal agent on the user's Mac with full tool \
    access. You may run shell commands, read and edit files anywhere the OS allows, \
    use the network, and follow installed skills. Prefer the project working \
    directory when one is set, but you are not sandboxed to it. Be careful with \
    destructive actions (rm -rf, force-push, dropping data) — confirm briefly when \
    the blast radius is large, then execute when the user is clear. Be direct and \
    complete. Use available skills when they match the task.
    """

    /// Restricted chat prompt when full access is off.
    static let restrictedSystemPrompt = ClaudeCLIDefaults.generalAssistantSystemPrompt
}

extension Notification.Name {
    /// Posted when `ProdigyAccessSettings.fullMacAccess` changes. `object` is `Bool`.
    static let prodigyAccessModeDidChange = Notification.Name("prodigy.accessModeDidChange")
}

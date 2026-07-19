import Foundation
import SwiftData

/// Creates Projects (and their V1 primary thread) consistently for picker,
/// "start empty", and quick-chat entry points.
enum ProjectFactory {
    /// Default parent for "start empty" Projects: `~/Projects`.
    static var defaultProjectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects", isDirectory: true)
    }

    /// Creates `~/Projects/<name>` (or a unique sibling if the name collides)
    /// and inserts a Project + primary ChatThread.
    @discardableResult
    static func createEmpty(
        named name: String,
        in context: ModelContext
    ) throws -> WorkspaceProject {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = trimmed.isEmpty ? "Untitled Project" : trimmed
        let folderURL = try ensureUniqueFolder(
            under: defaultProjectsRoot,
            preferredName: safeName
        )
        return insertProject(
            name: safeName,
            folderPath: folderURL.path,
            isQuickChat: false,
            isHiddenFromSidebar: false,
            in: context
        )
    }

    /// Binds a Project to an existing directory chosen via the folder picker.
    /// Name defaults to the folder's last path component when `name` is empty.
    @discardableResult
    static func createFromExistingFolder(
        url: URL,
        name: String?,
        in context: ModelContext
    ) -> WorkspaceProject {
        let folderName = url.lastPathComponent
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedName = trimmed.isEmpty ? folderName : trimmed
        return insertProject(
            name: resolvedName,
            folderPath: url.path,
            isQuickChat: false,
            isHiddenFromSidebar: false,
            in: context
        )
    }

    /// "Quick chat" entry point: real Project under `~/Projects/Quick Chat`,
    /// initially hidden from the sidebar (T11 / Pass 7 #13).
    @discardableResult
    static func createQuickChat(in context: ModelContext) throws -> WorkspaceProject {
        let folderURL = try ensureUniqueFolder(
            under: defaultProjectsRoot,
            preferredName: "Quick Chat"
        )
        return insertProject(
            name: "Quick Chat",
            folderPath: folderURL.path,
            isQuickChat: true,
            isHiddenFromSidebar: true,
            in: context
        )
    }

    /// Promote a quick-chat Project so it appears in the sidebar like any other.
    static func promoteToSidebar(_ project: WorkspaceProject, newName: String? = nil) {
        if let newName {
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                project.name = trimmed
            }
        }
        project.isHiddenFromSidebar = false
        project.isQuickChat = false
    }

    // MARK: - Internals

    private static func insertProject(
        name: String,
        folderPath: String,
        isQuickChat: Bool,
        isHiddenFromSidebar: Bool,
        in context: ModelContext
    ) -> WorkspaceProject {
        let project = WorkspaceProject(
            name: name,
            folderPath: folderPath,
            isHiddenFromSidebar: isHiddenFromSidebar,
            isQuickChat: isQuickChat
        )
        let thread = ChatThread(title: "Chat", project: project)
        project.threads = [thread]
        context.insert(project)
        context.insert(thread)
        return project
    }

    /// Ensures `under/<preferredName>` exists; if it already exists and is non-empty
    /// of *our* projects we still reuse the path for empty folders, otherwise
    /// append " 2", " 3", …
    private static func ensureUniqueFolder(
        under parent: URL,
        preferredName: String
    ) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)

        var candidate = parent.appendingPathComponent(preferredName, isDirectory: true)
        var suffix = 2
        while fm.fileExists(atPath: candidate.path) {
            // Reuse an existing empty directory; otherwise pick a free name.
            if isEmptyDirectory(candidate) {
                break
            }
            candidate = parent.appendingPathComponent(
                "\(preferredName) \(suffix)",
                isDirectory: true
            )
            suffix += 1
        }
        try fm.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }

    private static func isEmptyDirectory(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        return contents.isEmpty
    }
}

// MARK: - Agent factory

enum AgentFactory {
    @discardableResult
    static func create(
        name: String,
        systemPrompt: String,
        in context: ModelContext
    ) -> Agent {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let agent = Agent(
            name: trimmedName.isEmpty ? "New Agent" : trimmedName,
            systemPrompt: systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        context.insert(agent)
        return agent
    }

    /// Ensures a (Project, Agent) conversation thread exists; returns it.
    /// Persona is shared; history is per-Project.
    @discardableResult
    static func thread(
        for agent: Agent,
        in project: WorkspaceProject,
        context: ModelContext
    ) -> ChatThread {
        if let existing = project.thread(for: agent) {
            return existing
        }
        let thread = ChatThread(
            title: agent.name,
            project: project,
            agent: agent
        )
        context.insert(thread)
        return thread
    }
}

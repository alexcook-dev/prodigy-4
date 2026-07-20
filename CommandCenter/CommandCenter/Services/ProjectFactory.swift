import Foundation
import SwiftData

/// Creates Projects / Workspaces (and their V1 primary thread) consistently for
/// picker, "start empty", and quick-chat entry points.
enum ProjectFactory {
    /// Default parent for "start empty" Projects: `~/Projects`.
    static var defaultProjectsRoot: URL {
        defaultRoot(for: .project)
    }

    /// Default parent for "start empty" Workspaces: `~/Workspaces`.
    static var defaultWorkspacesRoot: URL {
        defaultRoot(for: .workspace)
    }

    static func defaultRoot(for kind: WorkspaceContainerKind) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(kind.defaultFolderParentName, isDirectory: true)
    }

    /// Creates `~/Projects/<name>` or `~/Workspaces/<name>` (or a unique sibling)
    /// and inserts a container + primary ChatThread.
    @discardableResult
    static func createEmpty(
        named name: String,
        kind: WorkspaceContainerKind = .project,
        in context: ModelContext
    ) throws -> WorkspaceProject {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = kind == .workspace ? "Untitled Workspace" : "Untitled Project"
        let safeName = trimmed.isEmpty ? fallback : trimmed
        let folderURL = try ensureUniqueFolder(
            under: defaultRoot(for: kind),
            preferredName: safeName
        )
        return insertProject(
            name: safeName,
            folderPath: folderURL.path,
            isQuickChat: false,
            isHiddenFromSidebar: false,
            kind: kind,
            in: context
        )
    }

    /// Binds a Project/Workspace to an existing directory chosen via the folder picker.
    /// Name defaults to the folder's last path component when `name` is empty.
    @discardableResult
    static func createFromExistingFolder(
        url: URL,
        name: String?,
        kind: WorkspaceContainerKind = .project,
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
            kind: kind,
            in: context
        )
    }

    /// "Quick chat" entry point: real Project rooted at the user's home folder
    /// so Files defaults to `~` until a Project with its own folder is selected.
    @discardableResult
    static func createQuickChat(in context: ModelContext) throws -> WorkspaceProject {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return insertProject(
            name: "Quick Chat",
            folderPath: home,
            isQuickChat: true,
            isHiddenFromSidebar: true,
            kind: .project,
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
        kind: WorkspaceContainerKind,
        in context: ModelContext
    ) -> WorkspaceProject {
        let project = WorkspaceProject(
            name: name,
            folderPath: folderPath,
            isHiddenFromSidebar: isHiddenFromSidebar,
            isQuickChat: isQuickChat,
            kind: kind
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

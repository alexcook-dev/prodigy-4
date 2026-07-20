import Foundation

// MARK: - Model

/// A reusable skill package shared across Claude and Grok (and any future models).
///
/// Canonical store: `~/.prodigy/skills/<slug>/SKILL.md`
/// Synced via symlink into `~/.claude/skills/<slug>` and `~/.grok/skills/<slug>`
/// so both CLIs discover the same skills natively.
struct ProdigySkill: Identifiable, Hashable, Sendable {
    /// Folder name / slash-command name (kebab-case).
    var slug: String
    var name: String
    var description: String
    var body: String
    /// When false, skill stays on disk but is not injected or preferred.
    var enabled: Bool

    var id: String { slug }

    /// Full SKILL.md contents.
    func skillMarkdown() -> String {
        var lines: [String] = [
            "---",
            "name: \(name.isEmpty ? slug : name)",
            "description: \(yamlEscape(description))",
            "---",
            "",
            body.trimmingCharacters(in: .whitespacesAndNewlines),
            "",
        ]
        if !enabled {
            // Comment marker for humans; enabled flag lives in index JSON.
            lines.insert("<!-- prodigy-disabled -->", at: 0)
        }
        return lines.joined(separator: "\n")
    }

    private func yamlEscape(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(":") || trimmed.contains("#") || trimmed.contains("\"")
            || trimmed.contains("\n") || trimmed.hasPrefix("'") {
            let escaped = trimmed.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return trimmed.isEmpty ? "\"\"" : trimmed
    }
}

// MARK: - Service

/// Manages Prodigy skills and keeps Claude + Grok skill directories in sync.
@MainActor
final class ProdigySkillsService: ObservableObject {
    static let shared = ProdigySkillsService()

    @Published private(set) var skills: [ProdigySkill] = []
    @Published private(set) var lastError: String?

    private let fm = FileManager.default
    private let indexFileName = "index.json"

    /// `~/.prodigy/skills`
    var skillsRoot: URL {
        fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".prodigy", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }

    private var claudeSkillsRoot: URL {
        fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }

    private var grokSkillsRoot: URL {
        fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }

    private var indexURL: URL {
        skillsRoot.appendingPathComponent(indexFileName)
    }

    private init() {
        try? ensureRoots()
        reload()
    }

    // MARK: - Public API

    func reload() {
        lastError = nil
        do {
            try ensureRoots()
            let enabledMap = loadEnabledMap()
            var found: [ProdigySkill] = []
            let entries = try fm.contentsOfDirectory(
                at: skillsRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            for dir in entries {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }
                let skillFile = dir.appendingPathComponent("SKILL.md")
                guard fm.fileExists(atPath: skillFile.path),
                      let text = try? String(contentsOf: skillFile, encoding: .utf8) else {
                    continue
                }
                let slug = dir.lastPathComponent
                let parsed = Self.parseSkillMarkdown(text, slug: slug)
                var skill = parsed
                skill.enabled = enabledMap[slug] ?? true
                found.append(skill)
            }
            skills = found.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            // Keep Claude/Grok mirrors aligned after reload.
            try resyncAllMirrors()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Create a new skill and sync to Claude + Grok.
    @discardableResult
    func addSkill(
        name: String,
        description: String,
        body: String = "# Instructions\n\nDescribe what this skill should do.\n"
    ) throws -> ProdigySkill {
        let slug = Self.slugify(name)
        guard !slug.isEmpty else {
            throw SkillsError.invalidName
        }
        if skills.contains(where: { $0.slug == slug }) {
            throw SkillsError.duplicate(slug)
        }
        try ensureRoots()
        let skill = ProdigySkill(
            slug: slug,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? slug : name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            body: body,
            enabled: true
        )
        try writeSkill(skill)
        try syncMirrors(for: skill)
        saveEnabled(slug: slug, enabled: true)
        reload()
        return skill
    }

    /// Update an existing skill (by slug).
    func updateSkill(_ skill: ProdigySkill) throws {
        guard skills.contains(where: { $0.slug == skill.slug })
                || fm.fileExists(atPath: skillsRoot.appendingPathComponent(skill.slug).path) else {
            throw SkillsError.notFound(skill.slug)
        }
        try writeSkill(skill)
        try syncMirrors(for: skill)
        saveEnabled(slug: skill.slug, enabled: skill.enabled)
        reload()
    }

    func setEnabled(slug: String, enabled: Bool) throws {
        guard var skill = skills.first(where: { $0.slug == slug }) else {
            throw SkillsError.notFound(slug)
        }
        skill.enabled = enabled
        try updateSkill(skill)
    }

    func deleteSkill(slug: String) throws {
        let dir = skillsRoot.appendingPathComponent(slug, isDirectory: true)
        if fm.fileExists(atPath: dir.path) {
            try fm.removeItem(at: dir)
        }
        removeMirror(at: claudeSkillsRoot.appendingPathComponent(slug))
        removeMirror(at: grokSkillsRoot.appendingPathComponent(slug))
        removeEnabled(slug: slug)
        reload()
    }

    /// Import a folder containing SKILL.md (or a SKILL.md file) into the store.
    @discardableResult
    func importFromURL(_ url: URL) throws -> ProdigySkill {
        let skillFile: URL
        let preferredSlug: String
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            skillFile = url.appendingPathComponent("SKILL.md")
            preferredSlug = url.lastPathComponent
        } else {
            skillFile = url
            preferredSlug = url.deletingPathExtension().lastPathComponent
        }
        guard fm.fileExists(atPath: skillFile.path),
              let text = try? String(contentsOf: skillFile, encoding: .utf8) else {
            throw SkillsError.invalidImport
        }
        var skill = Self.parseSkillMarkdown(text, slug: Self.slugify(preferredSlug))
        if skills.contains(where: { $0.slug == skill.slug }) {
            skill.slug = uniqueSlug(skill.slug)
        }
        skill.enabled = true
        try writeSkill(skill)
        try syncMirrors(for: skill)
        saveEnabled(slug: skill.slug, enabled: true)
        reload()
        return skill
    }

    /// Enabled skills only — for system-prompt injection.
    var enabledSkills: [ProdigySkill] {
        skills.filter(\.enabled)
    }

    /// Markdown block injected into every turn so both models see the same skill catalog.
    func systemPromptSkillsBlock() -> String {
        let active = enabledSkills
        guard !active.isEmpty else { return "" }
        var lines: [String] = [
            "",
            "## Prodigy skills (shared across Claude + Grok)",
            "When a task matches a skill, follow that skill's instructions closely.",
            "Skills live in ~/.prodigy/skills and are mirrored for both CLIs.",
            "",
        ]
        for skill in active {
            let desc = skill.description.isEmpty ? "(no description)" : skill.description
            lines.append("### /\(skill.slug) — \(skill.name)")
            lines.append(desc)
            lines.append("")
            // Include body so models without native skill load still get the procedure.
            let body = skill.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                lines.append(body)
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Disk

    private func ensureRoots() throws {
        try fm.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: claudeSkillsRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: grokSkillsRoot, withIntermediateDirectories: true)
    }

    private func writeSkill(_ skill: ProdigySkill) throws {
        let dir = skillsRoot.appendingPathComponent(skill.slug, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("SKILL.md")
        try skill.skillMarkdown().write(to: file, atomically: true, encoding: .utf8)
    }

    private func syncMirrors(for skill: ProdigySkill) throws {
        let source = skillsRoot.appendingPathComponent(skill.slug, isDirectory: true)
        try linkOrCopy(source: source, dest: claudeSkillsRoot.appendingPathComponent(skill.slug))
        try linkOrCopy(source: source, dest: grokSkillsRoot.appendingPathComponent(skill.slug))
    }

    private func resyncAllMirrors() throws {
        for skill in skills {
            try syncMirrors(for: skill)
        }
    }

    private func linkOrCopy(source: URL, dest: URL) throws {
        // Replace existing mirror (symlink or folder).
        if fm.fileExists(atPath: dest.path) || (try? dest.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            try? fm.removeItem(at: dest)
        }
        do {
            try fm.createSymbolicLink(at: dest, withDestinationURL: source)
        } catch {
            // Fall back to copy if symlink fails (e.g. cross-volume edge cases).
            try fm.copyItem(at: source, to: dest)
        }
    }

    private func removeMirror(at url: URL) {
        try? fm.removeItem(at: url)
    }

    private func uniqueSlug(_ base: String) -> String {
        var candidate = base
        var n = 2
        while skills.contains(where: { $0.slug == candidate })
            || fm.fileExists(atPath: skillsRoot.appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
    }

    // MARK: - Enabled index

    private struct IndexDTO: Codable {
        var enabled: [String: Bool]
    }

    private func loadEnabledMap() -> [String: Bool] {
        guard let data = try? Data(contentsOf: indexURL),
              let dto = try? JSONDecoder().decode(IndexDTO.self, from: data) else {
            return [:]
        }
        return dto.enabled
    }

    private func saveEnabled(slug: String, enabled: Bool) {
        var map = loadEnabledMap()
        map[slug] = enabled
        let dto = IndexDTO(enabled: map)
        if let data = try? JSONEncoder().encode(dto) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    private func removeEnabled(slug: String) {
        var map = loadEnabledMap()
        map.removeValue(forKey: slug)
        let dto = IndexDTO(enabled: map)
        if let data = try? JSONEncoder().encode(dto) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    // MARK: - Parsing

    static func slugify(_ raw: String) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var out = ""
        var lastDash = false
        for ch in lowered {
            if ch.isWhitespace || ch == "_" || ch == "/" {
                if !lastDash && !out.isEmpty {
                    out.append("-")
                    lastDash = true
                }
                continue
            }
            let s = String(ch)
            if s.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
                out.append(ch)
                lastDash = (ch == "-")
            } else if !lastDash && !out.isEmpty {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        while out.hasPrefix("-") { out.removeFirst() }
        return out
    }

    static func parseSkillMarkdown(_ text: String, slug: String) -> ProdigySkill {
        var name = slug
        var description = ""
        var body = text

        if text.hasPrefix("---") {
            let parts = text.split(separator: "---", maxSplits: 2, omittingEmptySubsequences: false)
            // ["", " frontmatter ", " body "]
            if parts.count >= 3 {
                let fm = String(parts[1])
                body = String(parts[2...].joined(separator: "---")).trimmingCharacters(in: .whitespacesAndNewlines)
                for line in fm.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("name:") {
                        name = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    } else if trimmed.hasPrefix("description:") {
                        description = trimmed.dropFirst("description:".count)
                            .trimmingCharacters(in: .whitespaces)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    }
                }
            }
        }
        if name.isEmpty { name = slug }
        return ProdigySkill(
            slug: slug,
            name: name,
            description: description,
            body: body,
            enabled: true
        )
    }
}

enum SkillsError: LocalizedError {
    case invalidName
    case duplicate(String)
    case notFound(String)
    case invalidImport

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Skill name must include letters or numbers."
        case .duplicate(let slug):
            return "A skill named “\(slug)” already exists."
        case .notFound(let slug):
            return "Skill “\(slug)” not found."
        case .invalidImport:
            return "Could not read SKILL.md from the selected path."
        }
    }
}

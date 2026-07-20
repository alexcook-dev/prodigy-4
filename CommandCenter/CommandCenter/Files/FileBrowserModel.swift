import Foundation
import SwiftUI

/// Observable state for the top-right file browser panel.
///
/// Loading contract (PLAN.md T6 / Next Step 4):
/// - Root open → enumerate **only** the root's immediate children, off-main.
/// - Expand a folder → enumerate **only** that folder's immediate children, off-main.
/// - Never recursively walk the tree up front.
@MainActor
final class FileBrowserModel: ObservableObject {

    // MARK: - Published UI state

    /// Directory the tree is rooted at. Defaults to the logged-in user's home (`~`).
    @Published private(set) var rootURL: URL?

    /// Immediate children of the root (populated lazily on `reloadRoot`).
    @Published private(set) var rootChildren: [FileNode] = []

    /// Paths currently expanded in the tree.
    @Published private(set) var expandedPaths: Set<String> = []

    /// Paths whose children are mid-flight (row shows spinner instead of chevron).
    @Published private(set) var loadingPaths: Set<String> = []

    /// Per-directory load errors shown as inline messages (permission denied, etc.).
    @Published private(set) var directoryErrors: [String: String] = [:]

    /// True while the root itself is loading.
    @Published private(set) var isRootLoading: Bool = false

    /// Root-level error when the root URL itself can't be listed.
    @Published private(set) var rootError: String?

    /// Primary selection (shift-range anchor + keyboard navigation).
    @Published var selectedURL: URL?

    /// Multi-select paths (absolute). Includes `selectedURL` when set.
    @Published private(set) var selectedPaths: Set<String> = []

    // MARK: - Private cache

    /// Immediate children keyed by parent directory path. Filled only on expand.
    private var childrenByPath: [String: [FileNode]] = [:]

    /// Generation token so stale async loads are dropped after root changes.
    private var loadGeneration: UInt64 = 0

    // MARK: - Init

    /// Always starts at the logged-in user's home (`/Users/<name>`), not a project folder.
    init() {
        // Seed root immediately so the UI never shows "no folder" on first paint.
        let home = Self.userHomeURL
        rootURL = home
        isRootLoading = true
        // Defer enumeration so ObservableObject is fully constructed.
        Task { @MainActor [weak self] in
            self?.setRoot(home)
        }
    }

    // MARK: - Root

    /// Logged-in user's home directory (`/Users/<name>`). Default Files root.
    static var userHomeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    }

    /// True when the tree is rooted at the current user's home folder.
    var isAtUserHome: Bool {
        guard let rootURL else { return false }
        return rootURL.standardizedFileURL.path == Self.userHomeURL.path
    }

    /// Can navigate to the parent of the current root (not above filesystem root).
    var canGoUp: Bool {
        guard let rootURL else { return false }
        let parent = rootURL.deletingLastPathComponent().standardizedFileURL
        return parent.path != rootURL.path && !parent.path.isEmpty
    }

    /// Bind the browser to a directory. Replaces the tree; does not walk descendants.
    /// Passing `nil` roots at the logged-in user's home folder.
    func setRoot(_ url: URL?) {
        let resolved = (url ?? Self.userHomeURL).standardizedFileURL
        // Skip no-op rebinds so project switches / onAppear don't thrash the tree
        // when we're already at the requested path.
        if rootURL?.path == resolved.path,
           !rootChildren.isEmpty || isRootLoading,
           rootError == nil {
            return
        }
        loadGeneration &+= 1
        rootURL = resolved
        rootChildren = []
        expandedPaths = []
        loadingPaths = []
        directoryErrors = [:]
        childrenByPath = [:]
        selectedURL = nil
        selectedPaths = []
        rootError = nil
        isRootLoading = true
        reloadRoot()
    }

    /// Jump to the logged-in user's home folder.
    func goHome() {
        setRoot(Self.userHomeURL)
    }

    /// Move the tree root up one directory (e.g. from `~/Documents` → `~`).
    func goUp() {
        guard canGoUp, let rootURL else { return }
        setRoot(rootURL.deletingLastPathComponent())
    }

    /// Common places under the user's home for the location picker.
    static var commonLocations: [(title: String, url: URL)] {
        let home = userHomeURL
        let fm = FileManager.default
        let candidates: [(String, URL)] = [
            ("Home", home),
            ("Desktop", home.appendingPathComponent("Desktop", isDirectory: true)),
            ("Documents", home.appendingPathComponent("Documents", isDirectory: true)),
            ("Downloads", home.appendingPathComponent("Downloads", isDirectory: true)),
            ("Projects", home.appendingPathComponent("Projects", isDirectory: true)),
        ]
        return candidates.filter { fm.fileExists(atPath: $0.1.path) }
    }

    // MARK: - Import / Move / Drop

    /// Copy dropped / imported files into `directory` (or root / selection).
    /// Returns destination URLs that were written.
    @discardableResult
    func importFiles(_ urls: [URL], into directory: URL? = nil) throws -> [URL] {
        let destDir = resolveDropDestination(directory)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        var written: [URL] = []
        for src in urls {
            let name = src.lastPathComponent
            let dest = uniqueDestination(in: destDir, preferredName: name)
            do {
                try FileManager.default.copyItem(at: src, to: dest)
            } catch {
                try FileManager.default.moveItem(at: src, to: dest)
            }
            written.append(dest)
        }
        refreshAfterMutation(affecting: [destDir])
        return written
    }

    /// Move files/folders into `destination`. Refreshes tree after.
    @discardableResult
    func moveItems(_ urls: [URL], to destination: URL) throws -> [URL] {
        let destDir = destination.standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destDir.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }

        var moved: [URL] = []
        var touchedParents: Set<String> = [destDir.path]
        for src in urls {
            let source = src.standardizedFileURL
            // Don't move a folder into itself or a descendant.
            if destDir.path == source.path
                || destDir.path.hasPrefix(source.path + "/") {
                continue
            }
            // Already in destination.
            if source.deletingLastPathComponent().path == destDir.path {
                continue
            }
            let dest = uniqueDestination(in: destDir, preferredName: source.lastPathComponent)
            touchedParents.insert(source.deletingLastPathComponent().path)
            try FileManager.default.moveItem(at: source, to: dest)
            moved.append(dest)
            selectedPaths.remove(source.path)
            if selectedURL?.path == source.path {
                selectedURL = dest
                selectedPaths.insert(dest.path)
            }
        }
        refreshAfterMutation(
            affecting: touchedParents.map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
        return moved
    }

    /// Handle a drag-and-drop of file URLs onto a folder (or root/selection when nil).
    /// Moves when sources are on the same volume; otherwise copies (Finder-like).
    @discardableResult
    func handleFileDrop(_ urls: [URL], onto destination: URL?) throws -> [URL] {
        let destDir = resolveDropDestination(destination)
        let sources = urls
            .map { $0.standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .filter { src in
                // Reject dropping a folder into itself or a descendant.
                destDir.path != src.path && !destDir.path.hasPrefix(src.path + "/")
            }

        guard !sources.isEmpty else { return [] }

        let sameVolume = sources.allSatisfy { Self.isSameVolume($0, destDir) }
        if sameVolume {
            return try moveItems(sources, to: destDir)
        }
        return try importFiles(sources, into: destDir)
    }

    /// Re-enumerate the root's immediate children only.
    func reloadRoot() {
        guard let rootURL else { return }
        let generation = loadGeneration
        isRootLoading = true
        rootError = nil

        Task {
            do {
                let children = try await FileTreeLoader.loadChildren(of: rootURL)
                guard generation == self.loadGeneration else { return }
                let sorted = Self.sortChildren(children, parent: rootURL)
                self.childrenByPath[rootURL.path] = sorted
                self.rootChildren = sorted
                self.isRootLoading = false
            } catch let error as FileTreeError {
                guard generation == self.loadGeneration else { return }
                self.rootChildren = []
                self.rootError = error.inlineMessage
                self.isRootLoading = false
            } catch {
                guard generation == self.loadGeneration else { return }
                self.rootChildren = []
                self.rootError = "Couldn't open folder"
                self.isRootLoading = false
            }
        }
    }

    // MARK: - Expansion

    func isExpanded(_ node: FileNode) -> Bool {
        expandedPaths.contains(node.id)
    }

    func isLoading(_ node: FileNode) -> Bool {
        loadingPaths.contains(node.id)
    }

    func children(of node: FileNode) -> [FileNode]? {
        childrenByPath[node.id]
    }

    func errorMessage(for node: FileNode) -> String? {
        directoryErrors[node.id]
    }

    /// Toggle expand/collapse. On first expand, loads immediate children off-main.
    func toggleExpand(_ node: FileNode) {
        guard node.isDirectory else { return }

        if expandedPaths.contains(node.id) {
            expandedPaths.remove(node.id)
            return
        }

        expandedPaths.insert(node.id)

        // Already cached from a previous expand — paint instantly.
        if childrenByPath[node.id] != nil {
            directoryErrors[node.id] = nil
            return
        }

        loadChildren(of: node)
    }

    /// Force re-fetch of a directory's immediate children (e.g. after permission fix).
    func refresh(_ node: FileNode) {
        guard node.isDirectory else { return }
        childrenByPath[node.id] = nil
        directoryErrors[node.id] = nil
        if expandedPaths.contains(node.id) {
            loadChildren(of: node)
        }
    }

    // MARK: - Selection

    /// URLs in the current multi-selection (stable path order).
    var selectedURLs: [URL] {
        selectedPaths.sorted().map { URL(fileURLWithPath: $0) }
    }

    func isSelected(_ node: FileNode) -> Bool {
        selectedPaths.contains(node.id)
    }

    /// Single-select (clears multi-select).
    func select(_ node: FileNode) {
        selectedURL = node.url
        selectedPaths = [node.id]
    }

    /// ⌘-click: add/remove from multi-select without clearing others.
    func toggleSelect(_ node: FileNode) {
        if selectedPaths.contains(node.id) {
            selectedPaths.remove(node.id)
            if selectedURL?.path == node.id {
                selectedURL = selectedPaths.sorted().first.map { URL(fileURLWithPath: $0) }
            }
        } else {
            selectedPaths.insert(node.id)
            selectedURL = node.url
        }
    }

    /// Shift-click: select contiguous visible range from anchor → node.
    func selectRange(to node: FileNode) {
        let entries = visibleEntryNodes()
        guard !entries.isEmpty else {
            select(node)
            return
        }
        let endIndex = entries.firstIndex(where: { $0.id == node.id }) ?? 0
        let startIndex: Int = {
            if let selectedURL,
               let i = entries.firstIndex(where: { $0.url.path == selectedURL.path }) {
                return i
            }
            return endIndex
        }()
        let lo = min(startIndex, endIndex)
        let hi = max(startIndex, endIndex)
        selectedPaths = Set(entries[lo...hi].map(\.id))
        selectedURL = node.url
    }

    /// ⌘A — select every currently visible entry.
    func selectAllVisible() {
        let entries = visibleEntryNodes()
        selectedPaths = Set(entries.map(\.id))
        selectedURL = entries.last?.url ?? selectedURL
    }

    /// Currently selected entry, if still visible in the tree.
    func selectedNode() -> FileNode? {
        guard let selectedURL else { return nil }
        return visibleEntryNodes().first { $0.url.path == selectedURL.path }
    }

    /// Move selection to the previous/next visible entry (arrow keys).
    func moveSelection(by delta: Int) {
        let entries = visibleEntryNodes()
        guard !entries.isEmpty else { return }

        if let selectedURL,
           let index = entries.firstIndex(where: { $0.url.path == selectedURL.path }) {
            let next = min(max(index + delta, 0), entries.count - 1)
            select(entries[next])
        } else {
            select(delta >= 0 ? entries[0] : entries[entries.count - 1])
        }
    }

    // MARK: - Flattened rows for List

    /// Depth-first visible rows based on expansion state only.
    /// Cost is O(visible rows), not O(total files on disk).
    func visibleRows() -> [FileTreeRow] {
        guard rootURL != nil else { return [] }
        var rows: [FileTreeRow] = []
        appendVisible(nodes: rootChildren, depth: 0, into: &rows)
        return rows
    }

    // MARK: - Private

    private func loadChildren(of node: FileNode) {
        let generation = loadGeneration
        loadingPaths.insert(node.id)
        directoryErrors[node.id] = nil

        Task {
            do {
                let children = try await FileTreeLoader.loadChildren(of: node.url)
                guard generation == self.loadGeneration else { return }
                self.childrenByPath[node.id] = Self.sortChildren(children, parent: node.url)
                self.loadingPaths.remove(node.id)
            } catch let error as FileTreeError {
                guard generation == self.loadGeneration else { return }
                self.childrenByPath[node.id] = []
                self.directoryErrors[node.id] = error.inlineMessage
                self.loadingPaths.remove(node.id)
            } catch {
                guard generation == self.loadGeneration else { return }
                self.childrenByPath[node.id] = []
                self.directoryErrors[node.id] = "Couldn't open folder"
                self.loadingPaths.remove(node.id)
            }
        }
    }

    private func appendVisible(
        nodes: [FileNode],
        depth: Int,
        into rows: inout [FileTreeRow]
    ) {
        for node in nodes {
            rows.append(FileTreeRow(node: node, depth: depth))

            guard node.isDirectory, expandedPaths.contains(node.id) else { continue }

            if let error = directoryErrors[node.id] {
                rows.append(
                    FileTreeRow(
                        node: node,
                        depth: depth + 1,
                        kind: .inlineError(error)
                    )
                )
                continue
            }

            if loadingPaths.contains(node.id) {
                // Spinner lives on the parent row (chevron replacement); no extra row.
                continue
            }

            if let kids = childrenByPath[node.id] {
                if kids.isEmpty {
                    rows.append(
                        FileTreeRow(
                            node: node,
                            depth: depth + 1,
                            kind: .emptyFolder
                        )
                    )
                } else {
                    appendVisible(nodes: kids, depth: depth + 1, into: &rows)
                }
            }
        }
    }

    private func visibleEntryNodes() -> [FileNode] {
        visibleRows().compactMap { row in
            if case .entry = row.kind { return row.node }
            return nil
        }
    }

    private func resolveDropDestination(_ destination: URL?) -> URL {
        if let destination {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDir),
               isDir.boolValue {
                return destination.standardizedFileURL
            }
            return destination.deletingLastPathComponent().standardizedFileURL
        }
        if let selected = selectedURL {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: selected.path, isDirectory: &isDir),
               isDir.boolValue {
                return selected.standardizedFileURL
            }
            return selected.deletingLastPathComponent().standardizedFileURL
        }
        return (rootURL ?? Self.userHomeURL).standardizedFileURL
    }

    private func uniqueDestination(in destDir: URL, preferredName: String) -> URL {
        var dest = destDir.appendingPathComponent(preferredName)
        guard FileManager.default.fileExists(atPath: dest.path) else { return dest }
        let base = dest.deletingPathExtension().lastPathComponent
        let ext = dest.pathExtension
        var i = 2
        repeat {
            let n = ext.isEmpty ? "\(base)-\(i)" : "\(base)-\(i).\(ext)"
            dest = destDir.appendingPathComponent(n)
            i += 1
        } while FileManager.default.fileExists(atPath: dest.path)
        return dest
    }

    /// Invalidate and re-list directories touched by a move/copy.
    private func refreshAfterMutation(affecting directories: [URL]) {
        var unique = Set(directories.map { $0.standardizedFileURL.path })
        if let root = rootURL?.path {
            unique.insert(root)
        }
        for path in unique {
            childrenByPath.removeValue(forKey: path)
            if path == rootURL?.path {
                reloadRoot()
            } else if expandedPaths.contains(path) {
                let url = URL(fileURLWithPath: path, isDirectory: true)
                let node = FileNode(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: true,
                    isSymbolicLink: false
                )
                refresh(node)
            }
        }
    }

    private static func isSameVolume(_ a: URL, _ b: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeURLKey]
        guard
            let aVol = try? a.resourceValues(forKeys: keys).volume,
            let bVol = try? b.resourceValues(forKeys: keys).volume
        else {
            return true
        }
        return aVol.standardizedFileURL.path == bVol.standardizedFileURL.path
    }

    /// Finder-like home order: Desktop, Documents, Downloads, … then other dirs, then files.
    private static func sortChildren(_ nodes: [FileNode], parent: URL) -> [FileNode] {
        let homePath = userHomeURL.path
        let isHome = parent.standardizedFileURL.path == homePath
        let priority: [String: Int] = [
            "Desktop": 0,
            "Documents": 1,
            "Downloads": 2,
            "Movies": 3,
            "Music": 4,
            "Pictures": 5,
            "Public": 6,
            "Applications": 7,
            "Library": 8,
        ]

        return nodes.sorted { lhs, rhs in
            if isHome {
                let lp = priority[lhs.name] ?? 100
                let rp = priority[rhs.name] ?? 100
                if lp != rp { return lp < rp }
            }
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

// MARK: - Row model

/// One row in the flattened tree list (file, folder, empty placeholder, or error).
struct FileTreeRow: Identifiable, Hashable {
    enum Kind: Hashable {
        case entry
        case emptyFolder
        case inlineError(String)
    }

    /// Unique per visible row (synthetic rows need a suffix so they don't collide).
    var id: String {
        switch kind {
        case .entry:
            return node.id
        case .emptyFolder:
            return node.id + "::empty"
        case .inlineError:
            return node.id + "::error"
        }
    }

    let node: FileNode
    let depth: Int
    let kind: Kind

    init(node: FileNode, depth: Int, kind: Kind = .entry) {
        self.node = node
        self.depth = depth
        self.kind = kind
    }
}

// MARK: - Path display helpers

enum FilePathDisplay {
    /// Shorten absolute paths under home to `~/…` for the panel header.
    static func compact(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

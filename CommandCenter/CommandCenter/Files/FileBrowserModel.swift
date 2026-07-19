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

    /// Directory the tree is rooted at (Project working folder once T3/T11 lands).
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

    /// Currently selected file or folder URL (drives highlight + preview request).
    @Published var selectedURL: URL?

    // MARK: - Private cache

    /// Immediate children keyed by parent directory path. Filled only on expand.
    private var childrenByPath: [String: [FileNode]] = [:]

    /// Generation token so stale async loads are dropped after root changes.
    private var loadGeneration: UInt64 = 0

    // MARK: - Root

    /// Bind the browser to a project working directory (or any folder).
    /// Replaces the tree; does not walk descendants.
    func setRoot(_ url: URL?) {
        loadGeneration &+= 1
        rootURL = url?.standardizedFileURL
        rootChildren = []
        expandedPaths = []
        loadingPaths = []
        directoryErrors = [:]
        childrenByPath = [:]
        selectedURL = nil
        rootError = nil

        guard url != nil else {
            isRootLoading = false
            return
        }
        reloadRoot()
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
                self.childrenByPath[rootURL.path] = children
                self.rootChildren = children
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

    func select(_ node: FileNode) {
        selectedURL = node.url
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
                self.childrenByPath[node.id] = children
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

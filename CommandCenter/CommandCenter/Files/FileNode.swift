import Foundation

/// One immediate child of a directory in the file browser tree.
///
/// Nodes are never built by recursive walks — only the directory currently
/// being expanded is enumerated (see `FileTreeLoader`).
struct FileNode: Identifiable, Hashable, Sendable {
    /// Stable identity for list rows / expansion state: the absolute path.
    var id: String { url.path }

    let url: URL
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool

    var displayName: String {
        isDirectory ? "\(name)/" : name
    }
}

/// Failures surfaced as inline row messages (never silent omission).
enum FileTreeError: LocalizedError, Sendable {
    case notADirectory(URL)
    case accessDenied(URL, underlying: String)
    case notFound(URL)

    var errorDescription: String? {
        switch self {
        case .notADirectory(let url):
            return "Not a directory: \(url.lastPathComponent)"
        case .accessDenied(let url, _):
            return "Permission denied: \(url.lastPathComponent)"
        case .notFound(let url):
            return "Missing: \(url.lastPathComponent)"
        }
    }

    /// Short copy for the tree row (Interaction States: permission-denied → inline message).
    var inlineMessage: String {
        switch self {
        case .accessDenied:
            return "Permission denied"
        case .notADirectory:
            return "Not a folder"
        case .notFound:
            return "Not found"
        }
    }
}

import Foundation

/// FileManager enumeration that always runs off the main thread and only
/// returns a directory's **immediate** children — never a recursive walk.
///
/// PLAN.md Next Step 4 / eng-review 4A: a real home directory holds 100k+ files;
/// eager recursion would hang the UI on first open.
enum FileTreeLoader {
    /// Resource keys fetched once per entry during enumeration.
    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .nameKey,
        .isRegularFileKey,
    ]

    /// Enumerate only `directoryURL`'s immediate children, off the main actor.
    ///
    /// - Parameter includeHidden: When false (default), skips dotfiles — matches
    ///   a typical Finder-style browser for daily work.
    static func loadChildren(
        of directoryURL: URL,
        includeHidden: Bool = false
    ) async throws -> [FileNode] {
        // Detach so FileManager I/O never touches the main thread, even when
        // a directory has tens of thousands of immediate entries.
        try await Task.detached(priority: .userInitiated) {
            try Self.enumerateImmediateChildren(
                of: directoryURL,
                includeHidden: includeHidden
            )
        }.value
    }

    // MARK: - Off-main work

    nonisolated private static func enumerateImmediateChildren(
        of directoryURL: URL,
        includeHidden: Bool
    ) throws -> [FileNode] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) else {
            throw FileTreeError.notFound(directoryURL)
        }
        guard isDirectory.boolValue else {
            throw FileTreeError.notADirectory(directoryURL)
        }

        var options: FileManager.DirectoryEnumerationOptions = [
            // Critical: never recurse. contentsOfDirectory is already shallow,
            // but we also skip package descendants for the same reason.
            .skipsPackageDescendants,
            .skipsSubdirectoryDescendants,
        ]
        if !includeHidden {
            options.insert(.skipsHiddenFiles)
        }

        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: resourceKeys,
                options: options
            )
        } catch {
            throw FileTreeError.accessDenied(
                directoryURL,
                underlying: error.localizedDescription
            )
        }

        var nodes: [FileNode] = []
        nodes.reserveCapacity(urls.count)

        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(resourceKeys))
            let name = values?.name ?? url.lastPathComponent
            let isSymlink = values?.isSymbolicLink ?? false
            // Treat packages / bundles as files (non-expandable) unless they're
            // real directories; isDirectory is true for folders and for some packages.
            var isDir = values?.isDirectory ?? false
            if isDir, url.pathExtension == "app" {
                isDir = false
            }

            nodes.append(
                FileNode(
                    url: url,
                    name: name,
                    isDirectory: isDir,
                    isSymbolicLink: isSymlink
                )
            )
        }

        // Directories first, then case-insensitive name — stable, predictable tree.
        nodes.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        return nodes
    }
}

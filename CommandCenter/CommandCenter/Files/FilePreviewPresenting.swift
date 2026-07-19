import Foundation
import SwiftUI

// MARK: - Preview request

/// A file the user wants to open in the center pane's preview mode.
///
/// Built by the file browser; consumed by whatever hosts center-pane tabs.
/// Keep this free of chat/composer types — the chat view will map it later.
struct FilePreviewRequest: Identifiable, Hashable, Sendable {
    /// Identity is the file URL (one preview tab per path).
    var id: URL { url }

    let url: URL

    /// Optional 1-based line range when a selection exists in preview.
    /// Used by ⌘⏎ "Discuss in chat" (PLAN.md Next Step 4 / design review Pass 6 #3)
    /// once the composer exists. Always nil until selection UI lands.
    var lineRange: ClosedRange<Int>?

    init(url: URL, lineRange: ClosedRange<Int>? = nil) {
        self.url = url
        self.lineRange = lineRange
    }

    var fileName: String { url.lastPathComponent }

    /// Compact path for the preview chrome bar (e.g. `src/hero-v3.tsx`).
    func relativeDisplayPath(relativeTo root: URL?) -> String {
        guard let root else { return fileName }
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return FilePathDisplay.compact(url)
    }
}

// MARK: - Center-pane connection point

/// Connection point between the file browser and the center pane.
///
/// `WorkspaceSelection` conforms today; Wave 3 chat controller can own this later.
///
/// **Do not invent chat-view types here** — when chat lands, make its controller
/// conform to this protocol and pass it into `FileBrowserPaneView`.
@MainActor
protocol FilePreviewPresenting: AnyObject {
    /// Open (or focus) a file preview tab and make it the active center content.
    func presentFilePreview(_ request: FilePreviewRequest)

    /// Close a preview tab; if it was active, return to chat.
    func dismissFilePreview(id: FilePreviewRequest.ID)

    /// Unconditional switch to the Chat tab (⌘2). Preview stays open as a background tab.
    func activateChatTab()

    /// ⌘⏎ from a file preview: switch to chat and insert a lightweight path
    /// reference into the composer (plain text, user-editable — not auto-send).
    ///
    /// TODO(Wave 3 / T5): implement composer insertion once the chat composer exists.
    func discussInChat(_ request: FilePreviewRequest)
}

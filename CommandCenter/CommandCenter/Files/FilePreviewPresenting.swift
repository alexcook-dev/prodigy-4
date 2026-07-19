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

// MARK: - Center-pane connection point (stub for Wave 3)

/// Connection point between the file browser and the center pane.
///
/// The real chat view (Wave 3 / T5) will own tabs, the composer, and preview
/// flip behavior. Until then, `FilePreviewSession` is the interim host.
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
    /// Signature is stable so the preview chrome can call it now.
    func discussInChat(_ request: FilePreviewRequest)
}

// MARK: - Which center surface is showing

/// Active center-pane surface. Chat is always available; previews are additive tabs.
enum CenterSurface: Hashable {
    case chat
    case filePreview(URL)
}

// MARK: - Interim session (replaced by chat controller in Wave 3)

/// Owns open file-preview tabs and which center surface is active.
///
/// TODO(Wave 3 / T5): Replace this class with the real center-pane / chat
/// controller that owns the tab bar (chat + file-preview tabs only — never a
/// second chat thread per T11) and the composer for "Discuss in chat".
/// Keep `FilePreviewPresenting` as the file-browser-facing contract.
@MainActor
final class FilePreviewSession: ObservableObject, FilePreviewPresenting {

    /// Open preview tabs, in open order. One entry per URL.
    @Published private(set) var openPreviews: [FilePreviewRequest] = []

    /// What the center pane body shows right now.
    @Published var activeSurface: CenterSurface = .chat

    // MARK: FilePreviewPresenting

    func presentFilePreview(_ request: FilePreviewRequest) {
        if let index = openPreviews.firstIndex(where: { $0.url == request.url }) {
            // Refresh metadata (e.g. line range) and focus existing tab.
            openPreviews[index] = request
        } else {
            openPreviews.append(request)
        }
        activeSurface = .filePreview(request.url)
    }

    func dismissFilePreview(id: FilePreviewRequest.ID) {
        let wasActive: Bool
        if case .filePreview(let url) = activeSurface, url == id {
            wasActive = true
        } else {
            wasActive = false
        }

        openPreviews.removeAll { $0.url == id }

        if wasActive {
            activeSurface = .chat
        }
    }

    func activateChatTab() {
        activeSurface = .chat
    }

    func discussInChat(_ request: FilePreviewRequest) {
        // Switch to chat so the gesture feels right even before the composer exists.
        activateChatTab()

        // TODO(Wave 3 / T5): insert a plain-text reference into the composer, e.g.
        //   "Re: path/to/file.swift" or with line range "Re: path/to/file.swift:12-40"
        // Do NOT auto-send. User edits before sending.
        // Intentionally no-op beyond tab switch until the chat composer exists.
        _ = request
    }

    // MARK: Helpers

    var activePreview: FilePreviewRequest? {
        guard case .filePreview(let url) = activeSurface else { return nil }
        return openPreviews.first { $0.url == url }
    }

    func isPreviewActive(_ url: URL) -> Bool {
        if case .filePreview(let active) = activeSurface {
            return active == url
        }
        return false
    }
}

import AppKit
import SwiftUI

/// Loads and holds the contents of a single file for the center-pane preview.
///
/// Text is read off the main thread with a size cap so opening a multi-MB
/// binary/log never freezes the UI. Images use NSImage on a background task.
@MainActor
final class FilePreviewContentModel: ObservableObject {
    enum State {
        case idle
        case loading
        case text(String, lineCount: Int)
        case image(NSImage)
        case binaryUnsupported(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var url: URL?

    /// Skip full text load above this size (still shows a clear message).
    static let maxTextBytes: Int = 2 * 1024 * 1024

    private var loadTask: Task<Void, Never>?

    func load(_ url: URL) {
        loadTask?.cancel()
        self.url = url
        state = .loading

        let maxBytes = Self.maxTextBytes
        loadTask = Task {
            let result = await Self.readFile(at: url, maxTextBytes: maxBytes)
            guard !Task.isCancelled else { return }
            self.state = result
        }
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
    }

    // MARK: - Off-main read

    nonisolated private static func readFile(
        at url: URL,
        maxTextBytes: Int
    ) async -> State {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            guard fm.fileExists(atPath: url.path) else {
                return .failed("File not found")
            }

            // Images first (by extension — simple V1 heuristic).
            if isImageExtension(url.pathExtension) {
                if let image = NSImage(contentsOf: url), image.isValid {
                    return .image(image)
                }
                return .failed("Couldn't load image")
            }

            // Size check before reading full contents.
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            if size > maxTextBytes {
                let mb = String(format: "%.1f", Double(size) / (1024 * 1024))
                return .binaryUnsupported("File is \(mb) MB — too large for inline preview")
            }

            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
                return .failed("Permission denied or unreadable")
            }

            // Reject obvious binary (NUL bytes in the first chunk).
            let sample = data.prefix(8_192)
            if sample.contains(0) {
                return .binaryUnsupported("Binary file — no text preview")
            }

            guard let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else {
                return .binaryUnsupported("Couldn't decode as text")
            }

            let lines = text.reduce(into: 1) { count, ch in
                if ch == "\n" { count += 1 }
            }
            return .text(text, lineCount: lines)
        }.value
    }

    nonisolated private static func isImageExtension(_ ext: String) -> Bool {
        let e = ext.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "tiff", "tif", "bmp", "heic", "ico"]
            .contains(e)
    }
}

// MARK: - Preview body view

/// Center-pane file preview body (wf-3 #4): monospaced text or image, chrome bar below.
struct FilePreviewView: View {
    let request: FilePreviewRequest
    /// Project / browser root for relative path display.
    var rootURL: URL? = nil
    var onClose: () -> Void = {}
    var onDiscussInChat: () -> Void = {}

    @StateObject private var content = FilePreviewContentModel()

    var body: some View {
        VStack(spacing: 0) {
            previewBody
            chromeBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.centerBackground)
        .onAppear { content.load(request.url) }
        .onChange(of: request.url) { _, newURL in
            content.load(newURL)
        }
        .onDisappear { content.cancel() }
        // Esc closes this preview only — never window-level (PLAN.md keyboard contract).
        // Terminal first-responder ownership is enforced later (T10); this binding
        // lives on the preview view so it only fires when the preview is in hierarchy
        // and the focus path allows it.
        .focusable()
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var previewBody: some View {
        switch content.state {
        case .idle, .loading:
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading preview…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .text(let text, _):
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textRow)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .image(let image):
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .binaryUnsupported(let message):
            placeholderMessage(message)

        case .failed(let message):
            placeholderMessage(message, isError: true)
        }
    }

    private func placeholderMessage(_ message: String, isError: Bool = false) -> some View {
        VStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle" : "doc.questionmark")
                .font(.system(size: 22))
                .foregroundStyle(isError ? Theme.errorText : Theme.textSecondary)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(isError ? Theme.errorText : Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Chrome (wf-3 #4 bottom bar)

    private var chromeBar: some View {
        HStack(spacing: 10) {
            Text(pathLabel)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Text("esc")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Theme.kbdBackground)
                    )
                Text("back to chat")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)

                Text("·")
                    .foregroundStyle(Theme.textTertiary)

                Text("⌘⏎")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Theme.kbdBackground)
                    )
                Text("discuss in chat")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.borderHairline)
                .frame(height: 1)
        }
        // Clickable affordances for the same actions as the kbd hints.
        .contextMenu {
            Button("Back to chat") { onClose() }
            Button("Discuss in chat") { onDiscussInChat() }
        }
        .onTapGesture(count: 2) {
            // Double-click chrome returns to chat (light discovery affordance).
            onClose()
        }
        .onKeyPress(keys: [.return]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            onDiscussInChat()
            return .handled
        }
    }

    private var pathLabel: String {
        let path = request.relativeDisplayPath(relativeTo: rootURL)
        if case .text(_, let lineCount) = content.state {
            return "\(path) · \(lineCount) lines"
        }
        return path
    }
}

#Preview("Text preview") {
    FilePreviewView(
        request: FilePreviewRequest(url: URL(fileURLWithPath: "/tmp/example.swift"))
    )
    .frame(width: 640, height: 400)
    .preferredColorScheme(.dark)
}

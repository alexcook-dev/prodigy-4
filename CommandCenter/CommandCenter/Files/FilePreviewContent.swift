import AppKit
import SwiftUI
import WebKit

// MARK: - Design refs
// sc5 — HTML/renderable: path chip + Preview | Edit, rendered WebView canvas
// sc6 — Image: path chip, centered image on light/dark canvas
// sc7 — Text/code: path chip + copy, monospaced body with line numbers

/// Loads and holds the contents of a single file for the center-pane preview.
@MainActor
final class FilePreviewContentModel: ObservableObject {
    enum Kind {
        case text
        case image
        case html
        case binary
    }

    enum State {
        case idle
        case loading
        case text(String, lineCount: Int)
        case image(NSImage)
        case html(source: String, fileURL: URL)
        case binaryUnsupported(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var url: URL?
    @Published private(set) var kind: Kind = .text
    /// sc5: for HTML, toggle between rendered preview and source edit view.
    @Published var htmlMode: HTMLMode = .preview

    enum HTMLMode: String, CaseIterable, Identifiable {
        case preview
        case edit
        var id: String { rawValue }
        var title: String {
            switch self {
            case .preview: "Preview"
            case .edit: "Edit"
            }
        }
    }

    static let maxTextBytes: Int = 2 * 1024 * 1024

    private var loadTask: Task<Void, Never>?

    func load(_ url: URL) {
        loadTask?.cancel()
        self.url = url
        kind = Self.kind(for: url)
        htmlMode = .preview
        state = .loading

        let maxBytes = Self.maxTextBytes
        loadTask = Task {
            let result = await Self.readFile(at: url, maxTextBytes: maxBytes)
            guard !Task.isCancelled else { return }
            self.state = result
            if case .html = result {
                self.kind = .html
            } else if case .image = result {
                self.kind = .image
            } else if case .text = result {
                self.kind = .text
            }
        }
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
    }

    nonisolated static func kind(for url: URL) -> Kind {
        let ext = url.pathExtension.lowercased()
        if isImageExtension(ext) { return .image }
        if isHTMLExtension(ext) { return .html }
        return .text
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

            if isImageExtension(url.pathExtension) {
                if let image = NSImage(contentsOf: url), image.isValid {
                    return .image(image)
                }
                return .failed("Couldn't load image")
            }

            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            if size > maxTextBytes {
                let mb = String(format: "%.1f", Double(size) / (1024 * 1024))
                return .binaryUnsupported("File is \(mb) MB — too large for inline preview")
            }

            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
                return .failed("Permission denied or unreadable")
            }

            let sample = data.prefix(8_192)
            if sample.contains(0) {
                return .binaryUnsupported("Binary file — no text preview")
            }

            guard let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else {
                return .binaryUnsupported("Couldn't decode as text")
            }

            if isHTMLExtension(url.pathExtension) {
                return .html(source: text, fileURL: url)
            }

            let lines = text.reduce(into: 1) { count, ch in
                if ch == "\n" { count += 1 }
            }
            return .text(text, lineCount: lines)
        }.value
    }

    nonisolated private static func isImageExtension(_ ext: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "tiff", "tif", "bmp", "heic", "ico", "svg"]
            .contains(ext.lowercased())
    }

    nonisolated private static func isHTMLExtension(_ ext: String) -> Bool {
        ["html", "htm", "xhtml"].contains(ext.lowercased())
    }
}

// MARK: - Preview body view (sc5 / sc6 / sc7)

/// Center-pane file preview: image canvas, HTML WebView, or line-numbered text.
struct FilePreviewView: View {
    let request: FilePreviewRequest
    var rootURL: URL? = nil
    var onClose: () -> Void = {}
    var onDiscussInChat: () -> Void = {}

    @StateObject private var content = FilePreviewContentModel()
    @State private var hoveredLine: Int?

    var body: some View {
        VStack(spacing: 0) {
            pathBar
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
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
    }

    // MARK: - Path chip bar (sc5 / sc6 / sc7)

    private var pathBar: some View {
        HStack(spacing: 8) {
            pathChip

            Spacer(minLength: 8)

            if case .html = content.state {
                // sc5: Preview | Edit toggle
                Picker("", selection: $content.htmlMode) {
                    ForEach(FilePreviewContentModel.HTMLMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
                .controlSize(.small)
            } else if case .text = content.state {
                Button {
                    copyPathOrContents()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(Font.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy contents")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.centerBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.borderHairline.opacity(0.7))
                .frame(height: 1)
        }
    }

    private var pathChip: some View {
        HStack(spacing: 6) {
            Image(systemName: fileIconName)
                .font(Font.caption.weight(.semibold))
                .foregroundStyle(fileIconColor)

            Text(pathLabel)
                .font(Font.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.chipBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Theme.borderHairline, lineWidth: 1)
                )
        )
        .help(request.url.path)
    }

    private var fileIconName: String {
        switch content.kind {
        case .image: return "photo"
        case .html: return "chevron.left.forwardslash.chevron.right"
        case .text: return "doc.text"
        case .binary: return "doc"
        }
    }

    private var fileIconColor: Color {
        switch content.kind {
        case .image: return Color(nsColor: .systemGreen)
        case .html: return Color(nsColor: .systemOrange)
        case .text: return Theme.accent
        case .binary: return Theme.textTertiary
        }
    }

    private var pathLabel: String {
        request.relativeDisplayPath(relativeTo: rootURL)
    }

    private func copyPathOrContents() {
        let pb = NSPasteboard.general
        pb.clearContents()
        if case .text(let text, _) = content.state {
            pb.setString(text, forType: .string)
        } else if case .html(let source, _) = content.state {
            pb.setString(source, forType: .string)
        } else {
            pb.setString(request.url.path, forType: .string)
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
                    .font(Font.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .text(let text, let lineCount):
            // sc7: monospaced editor with line numbers
            TextEditorView(text: text, lineCount: lineCount)

        case .image(let image):
            // sc6: centered image on canvas
            ImagePreviewCanvas(image: image)

        case .html(let source, let fileURL):
            // sc5: rendered preview or source edit
            if content.htmlMode == .preview {
                HTMLPreviewWebView(fileURL: fileURL, html: source)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let lines = source.reduce(into: 1) { c, ch in if ch == "\n" { c += 1 } }
                TextEditorView(text: source, lineCount: lines)
            }

        case .binaryUnsupported(let message):
            placeholderMessage(message)

        case .failed(let message):
            placeholderMessage(message, isError: true)
        }
    }

    private func placeholderMessage(_ message: String, isError: Bool = false) -> some View {
        VStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle" : "doc.questionmark")
                .font(Font.title2)
                .foregroundStyle(isError ? Theme.errorText : Theme.textSecondary)
            Text(message)
                .font(Font.subheadline)
                .foregroundStyle(isError ? Theme.errorText : Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Bottom chrome

    private var chromeBar: some View {
        HStack(spacing: 10) {
            Text(statusLabel)
                .font(Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                kbd("esc")
                Text("back to chat")
                    .font(Font.caption)
                    .foregroundStyle(Theme.textSecondary)

                Text("·")
                    .foregroundStyle(Theme.textTertiary)

                kbd("⌘⏎")
                Text("discuss in chat")
                    .font(Font.caption)
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
        .contextMenu {
            Button("Back to chat") { onClose() }
            Button("Discuss in chat") { onDiscussInChat() }
        }
        .onTapGesture(count: 2) { onClose() }
        .onKeyPress(keys: [.return]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            onDiscussInChat()
            return .handled
        }
    }

    private func kbd(_ label: String) -> some View {
        Text(label)
            .font(Font.caption2.monospaced())
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Theme.kbdBackground)
            )
    }

    private var statusLabel: String {
        switch content.state {
        case .text(_, let lineCount):
            return "\(pathLabel) · \(lineCount) lines"
        case .image(let image):
            let size = image.size
            return "\(pathLabel) · \(Int(size.width))×\(Int(size.height))"
        case .html:
            return content.htmlMode == .preview
                ? "\(pathLabel) · preview"
                : "\(pathLabel) · source"
        default:
            return pathLabel
        }
    }
}

// MARK: - sc7 Text editor with line numbers

private struct TextEditorView: View {
    let text: String
    let lineCount: Int

    private let mono = Font.caption.monospaced()
    private let lineSpacing: CGFloat = 3

    private var gutterText: String {
        let n = max(lineCount, 1)
        return (1...n).map(String.init).joined(separator: "\n")
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 0) {
                // Gutter — same font/lineSpacing as body so rows stay aligned.
                Text(gutterText)
                    .font(mono)
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.trailing)
                    .lineSpacing(lineSpacing)
                    .padding(.top, 12)
                    .padding(.leading, 10)
                    .padding(.trailing, 10)
                    .padding(.bottom, 16)
                    .background(Theme.sidebarBackground.opacity(0.5))
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(Theme.borderHairline)
                            .frame(width: 1)
                    }

                // Source — single Text so selection spans lines (sc7).
                Text(text.isEmpty ? " " : text)
                    .font(mono)
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .lineSpacing(lineSpacing)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.top, 12)
                    .padding(.leading, 14)
                    .padding(.trailing, 20)
                    .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Theme.centerBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - sc6 Image canvas

private struct ImagePreviewCanvas: View {
    let image: NSImage

    var body: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(
                        maxWidth: max(geo.size.width - 48, 120),
                        maxHeight: max(geo.size.height - 48, 120)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                    .frame(
                        width: geo.size.width,
                        height: geo.size.height
                    )
            }
        }
        .background(Theme.centerBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - sc5 HTML WebView

private struct HTMLPreviewWebView: NSViewRepresentable {
    let fileURL: URL
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        load(into: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        // Reload only when path changes.
        if context.coordinator.loadedPath != fileURL.path {
            load(into: view)
            context.coordinator.loadedPath = fileURL.path
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func load(into view: WKWebView) {
        let dir = fileURL.deletingLastPathComponent()
        // Load from file URL so relative assets (css/images) resolve when present.
        view.loadFileURL(fileURL, allowingReadAccessTo: dir)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedPath: String?
    }
}

#Preview("Text preview") {
    FilePreviewView(
        request: FilePreviewRequest(url: URL(fileURLWithPath: "/tmp/example.swift"))
    )
    .frame(width: 640, height: 400)
}

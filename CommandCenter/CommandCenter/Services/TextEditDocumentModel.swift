import AppKit
import Foundation
import UniformTypeIdentifiers

/// Document model for the bottom-right **TextEdit** tab — open/save/edit like
/// macOS TextEdit for plain text (and RTF when the file is `.rtf`).
@MainActor
final class TextEditDocumentModel: ObservableObject {
    @Published var text: String = ""
    @Published private(set) var fileURL: URL?
    @Published private(set) var isDirty: Bool = false
    @Published private(set) var isRichText: Bool = false
    @Published var statusMessage: String?
    /// Attributed body when editing RTF (mirrors `text` for plain).
    @Published var attributedText: NSAttributedString = NSAttributedString(string: "")

    /// Preferred folder for Open/Save panels (project folder or Documents).
    var defaultDirectory: URL = FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
    ).first ?? FileManager.default.homeDirectoryForCurrentUser

    var displayName: String {
        if let fileURL {
            return fileURL.lastPathComponent
        }
        return "Untitled"
    }

    var windowTitle: String {
        isDirty ? "\(displayName) — Edited" : displayName
    }

    // MARK: - Mutations

    func updatePlainText(_ newValue: String) {
        guard !isRichText else { return }
        if text != newValue {
            text = newValue
            isDirty = true
            statusMessage = nil
        }
    }

    func updateAttributedText(_ newValue: NSAttributedString) {
        guard isRichText else { return }
        if !attributedText.isEqual(to: newValue) {
            attributedText = newValue
            text = newValue.string
            isDirty = true
            statusMessage = nil
        }
    }

    // MARK: - Document lifecycle

    func newDocument() {
        if isDirty {
            let proceed = confirmDiscardChanges()
            guard proceed else { return }
        }
        text = ""
        attributedText = NSAttributedString(string: "")
        fileURL = nil
        isDirty = false
        isRichText = false
        statusMessage = "New document"
    }

    func open() {
        if isDirty {
            let proceed = confirmDiscardChanges()
            guard proceed else { return }
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .utf8PlainText, .rtf, .text]
        panel.directoryURL = fileURL?.deletingLastPathComponent() ?? defaultDirectory
        panel.prompt = "Open"
        panel.message = "Open a text document"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    func open(url: URL) {
        let ext = url.pathExtension.lowercased()
        do {
            if ext == "rtf" {
                let data = try Data(contentsOf: url)
                if let attr = NSAttributedString(
                    rtf: data,
                    documentAttributes: nil
                ) {
                    attributedText = attr
                    text = attr.string
                    isRichText = true
                } else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            } else {
                let loaded = try String(contentsOf: url, encoding: .utf8)
                text = loaded
                attributedText = NSAttributedString(string: loaded)
                isRichText = false
            }
            fileURL = url
            isDirty = false
            statusMessage = "Opened \(url.lastPathComponent)"
            // Remember folder for next open/save.
            defaultDirectory = url.deletingLastPathComponent()
        } catch {
            statusMessage = "Couldn’t open: \(error.localizedDescription)"
            presentErrorAlert(title: "Couldn’t Open Document", message: error.localizedDescription)
        }
    }

    @discardableResult
    func save() -> Bool {
        if let fileURL {
            return write(to: fileURL)
        }
        return saveAs()
    }

    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = fileURL?.deletingLastPathComponent() ?? defaultDirectory
        panel.nameFieldStringValue = fileURL?.lastPathComponent
            ?? (isRichText ? "Untitled.rtf" : "Untitled.txt")
        if isRichText {
            panel.allowedContentTypes = [.rtf]
        } else {
            panel.allowedContentTypes = [.plainText, .utf8PlainText]
        }
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(to: url)
    }

    private func write(to url: URL) -> Bool {
        do {
            if isRichText || url.pathExtension.lowercased() == "rtf" {
                let range = NSRange(location: 0, length: attributedText.length)
                let data = try attributedText.data(
                    from: range,
                    documentAttributes: [
                        .documentType: NSAttributedString.DocumentType.rtf,
                    ]
                )
                try data.write(to: url, options: .atomic)
                isRichText = true
            } else {
                try text.write(to: url, atomically: true, encoding: .utf8)
                isRichText = false
            }
            fileURL = url
            isDirty = false
            statusMessage = "Saved \(url.lastPathComponent)"
            defaultDirectory = url.deletingLastPathComponent()
            return true
        } catch {
            statusMessage = "Couldn’t save: \(error.localizedDescription)"
            presentErrorAlert(title: "Couldn’t Save Document", message: error.localizedDescription)
            return false
        }
    }

    func toggleRichText() {
        if isRichText {
            // Flatten to plain.
            text = attributedText.string
            attributedText = NSAttributedString(string: text)
            isRichText = false
            isDirty = true
            statusMessage = "Converted to plain text"
        } else {
            attributedText = NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                    .foregroundColor: NSColor.labelColor,
                ]
            )
            isRichText = true
            isDirty = true
            statusMessage = "Converted to rich text"
        }
    }

    // MARK: - Alerts

    private func confirmDiscardChanges() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to \(displayName)?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            return save()
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    private func presentErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

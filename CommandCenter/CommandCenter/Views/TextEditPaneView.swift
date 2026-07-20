import AppKit
import SwiftUI

/// Bottom-right **TextEdit** tab — edit/save/open like macOS TextEdit.
struct TextEditPaneView: View {
    @ObservedObject var document: TextEditDocumentModel
    var isFocused: Bool = false

    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            editor
            statusBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.centerBackground)
        .onChange(of: isFocused) { _, focused in
            if focused { editorFocused = true }
        }
        .onAppear {
            if isFocused { editorFocused = true }
        }
        // ⌘S save, ⌘O open, ⌘N new (when this pane is focused).
        .onKeyPress(KeyEquivalent("s"), phases: .down) { press in
            guard isFocused || editorFocused else { return .ignored }
            guard press.modifiers.contains(.command) else { return .ignored }
            if press.modifiers.contains(.shift) {
                _ = document.saveAs()
            } else {
                _ = document.save()
            }
            return .handled
        }
        .onKeyPress(KeyEquivalent("o"), phases: .down) { press in
            guard isFocused || editorFocused else { return .ignored }
            guard press.modifiers == .command else { return .ignored }
            document.open()
            return .handled
        }
        .onKeyPress(KeyEquivalent("n"), phases: .down) { press in
            guard isFocused || editorFocused else { return .ignored }
            guard press.modifiers == .command else { return .ignored }
            document.newDocument()
            return .handled
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button {
                document.newDocument()
            } label: {
                Image(systemName: "doc.badge.plus")
            }
            .buttonStyle(.plain)
            .help("New (⌘N)")
            .foregroundStyle(Theme.textSecondary)

            Button {
                document.open()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .help("Open… (⌘O)")
            .foregroundStyle(Theme.textSecondary)

            Button {
                _ = document.save()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.plain)
            .help("Save (⌘S)")
            .foregroundStyle(Theme.textSecondary)

            Button {
                _ = document.saveAs()
            } label: {
                Image(systemName: "square.and.arrow.down.on.square")
            }
            .buttonStyle(.plain)
            .help("Save As… (⇧⌘S)")
            .foregroundStyle(Theme.textSecondary)

            Divider()
                .frame(height: 14)

            Button {
                document.toggleRichText()
            } label: {
                Text(document.isRichText ? "Rich Text" : "Plain Text")
                    .font(Font.caption.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Toggle plain / rich text")

            Spacer(minLength: 8)

            Text(document.windowTitle)
                .font(Font.caption)
                .foregroundStyle(document.isDirty ? Theme.accentText : Theme.textTertiary)
                .lineLimit(1)
                .help(document.fileURL?.path ?? "Unsaved document")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.centerBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.borderHairline)
                .frame(height: 1)
        }
    }

    // MARK: - Editor

    private var editor: some View {
        Group {
            if document.isRichText {
                RichTextEditView(
                    attributedText: Binding(
                        get: { document.attributedText },
                        set: { document.updateAttributedText($0) }
                    )
                )
            } else {
                SpellCheckedTextEditor(
                    text: Binding(
                        get: { document.text },
                        set: { document.updatePlainText($0) }
                    ),
                    font: .monospacedSystemFont(ofSize: 12.5, weight: .regular),
                    textColor: NSColor(named: "TextPrimary") ?? .labelColor
                )
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.centerBackground)
        .focused($editorFocused)
        .accessibilityLabel("TextEdit document")
    }

    // MARK: - Status

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let status = document.statusMessage {
                Text(status)
                    .font(Font.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            } else if let path = document.fileURL?.path {
                Text(path)
                    .font(Font.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Untitled — not saved")
                    .font(Font.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
            Text("\(document.text.count) characters")
                .font(Font.caption2)
                .foregroundStyle(Theme.textTertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Theme.elevatedSurface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.borderHairline)
                .frame(height: 1)
        }
    }
}

// MARK: - Rich text NSTextView

/// Editable rich text surface (RTF) for TextEdit-style documents.
private struct RichTextEditView: NSViewRepresentable {
    @Binding var attributedText: NSAttributedString

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.usesFontPanel = true
        textView.usesRuler = false
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(attributedText)

        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.attributedString().isEqual(to: attributedText) == false {
            let selected = textView.selectedRanges
            textView.textStorage?.setAttributedString(attributedText)
            textView.selectedRanges = selected
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditView
        weak var textView: NSTextView?

        init(_ parent: RichTextEditView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.attributedText = textView.attributedString()
        }
    }
}

#Preview {
    TextEditPaneView(document: TextEditDocumentModel(), isFocused: true)
        .frame(width: 360, height: 280)
        .preferredColorScheme(.dark)
}

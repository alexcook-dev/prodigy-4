import SwiftUI

/// Streaming-tolerant markdown renderer for assistant bubbles (T5).
///
/// Uses Foundation's `AttributedString` markdown parser with
/// `returnPartiallyParsedIfPossible` so incomplete fences / emphasis mid-stream
/// still render something useful instead of throwing blank. Re-parses the full
/// accumulated string on each delta — fine for chat-length replies.
struct StreamingMarkdownView: View {
    let text: String
    /// When true, appends a blinking caret after the last character (wf-3 #1).
    var isStreaming: Bool = false
    /// Append the "[partial — kept]" tag (T13 / wf-3 #2).
    var isPartial: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(rendered)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.accentText)
                .textSelection(.enabled)
                .lineSpacing(3)
                .frame(maxWidth: 720, alignment: .leading)

            if isPartial {
                Text("[partial — kept]")
                    .font(.system(size: 12).italic())
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var rendered: AttributedString {
        var base = parseMarkdown(text)
        if isStreaming {
            // Blinking caret (wf-3 #1) — block character after the last token.
            var block = AttributedString("▋")
            block.foregroundColor = .accentColor
            base.append(block)
        }
        return base
    }

    private func parseMarkdown(_ source: String) -> AttributedString {
        guard !source.isEmpty else { return AttributedString("") }

        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .returnPartiallyParsedIfPossible

        if let parsed = try? AttributedString(
            markdown: source,
            options: options,
            baseURL: nil
        ) {
            return parsed
        }
        // Absolute last resort — never blank the bubble on a parse failure.
        return AttributedString(source)
    }
}

#Preview("Streaming markdown") {
    StreamingMarkdownView(
        text: """
        Here's a **draft**:

        1. Lead with the ask
        2. One concrete detail

        ```swift
        print("hello")
        ```
        """,
        isStreaming: true
    )
    .padding()
    .frame(width: 480)
    .background(Theme.centerBackground)
    .preferredColorScheme(.dark)
}

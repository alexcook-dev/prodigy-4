import SwiftUI

/// Top-right file browser placeholder.
/// Real FileManager tree + lazy loading is T6; preview flip is later.
struct FileBrowserPaneView: View {
    var isFocused: Bool = false

    private let rows: [(indent: Int, icon: String, name: String, selected: Bool)] = [
        (0, "chevron.down", "src/", false),
        (1, "diamond.fill", "hero-v3.tsx", true),
        (1, "diamond", "nav.tsx", false),
        (0, "chevron.right", "assets/", false),
        (0, "chevron.right", "docs/", false),
    ]

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            fileList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.appBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.deepest)
                .frame(height: 1)
        }
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(Theme.focusRing, lineWidth: 2)
            }
        }
    }

    private var panelHeader: some View {
        HStack {
            Text("Files — ~/Projects/website")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .textCase(.uppercase)
                .tracking(0.6)
                .lineLimit(1)

            Spacer()

            Image(systemName: "chevron.up")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.borderHairline)
                .frame(height: 1)
        }
    }

    private var fileList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 6) {
                        Image(systemName: row.icon)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 14)

                        Text(row.name)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textRow)
                            .lineLimit(1)

                        Spacer(minLength: 0)
                    }
                    .padding(.leading, CGFloat(12 + row.indent * 12))
                    .padding(.trailing, 12)
                    .padding(.vertical, 3)
                    .background(row.selected ? Theme.fileSelectionFill : Color.clear)
                    .contentShape(Rectangle())
                }

                Text("File tree is a placeholder — lazy FileManager browser is T6.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    FileBrowserPaneView()
        .frame(width: 320, height: 280)
        .preferredColorScheme(.dark)
}

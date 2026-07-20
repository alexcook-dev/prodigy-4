import AppKit
import SwiftUI

/// Top-right file browser: FileManager tree with lazy per-directory loading.
///
/// Expand enumerates only that directory's immediate children, off the main
/// thread (PLAN.md T6 / Next Step 4). Selection asks a `FilePreviewPresenting`
/// host to flip the center pane into preview — the real chat view will take
/// over that host role in Wave 3.
struct FileBrowserPaneView: View {
    @ObservedObject var model: FileBrowserModel
    /// Interim `FilePreviewSession` today; chat controller tomorrow.
    var previewPresenter: FilePreviewPresenting?
    var isFocused: Bool = false

    /// Keyboard focus for Space / Enter / arrows when the Files pane is active.
    @FocusState private var listKeyboardFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            treeBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.centerBackground)
        .focusable()
        .focused($listKeyboardFocused)
        .onChange(of: isFocused) { _, focused in
            // When the workspace focuses Files (click / ⌘3), capture keyboard.
            listKeyboardFocused = focused
        }
        .onAppear {
            if isFocused { listKeyboardFocused = true }
        }
        // Finder-style: Space / Enter → preview selected file (or expand folder).
        .onKeyPress(.space) {
            guard isFocused || listKeyboardFocused else { return .ignored }
            activateSelected()
            return .handled
        }
        .onKeyPress(.return) {
            guard isFocused || listKeyboardFocused else { return .ignored }
            activateSelected()
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard isFocused || listKeyboardFocused else { return .ignored }
            model.moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard isFocused || listKeyboardFocused else { return .ignored }
            model.moveSelection(by: 1)
            return .handled
        }
    }

    // MARK: - Header

    private var panelHeader: some View {
        // sc1-style: "All files" chrome + utility icons.
        HStack(spacing: 10) {
            Text("All files")
                .font(Font.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .help(model.rootURL?.path ?? headerTitle)

            Text("Changes")
                .font(Font.subheadline)
                .foregroundStyle(Theme.textTertiary)
            Text("Checks")
                .font(Font.subheadline)
                .foregroundStyle(Theme.textTertiary)

            Spacer(minLength: 4)

            if model.rootURL != nil {
                Button {
                    model.reloadRoot()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(Font.caption.weight(.medium))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Reload folder")
            }

            Image(systemName: "magnifyingglass")
                .font(Font.caption.weight(.medium))
                .foregroundStyle(Theme.textTertiary)
                .help(headerTitle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.centerBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.borderHairline)
                .frame(height: 1)
        }
    }

    private var headerTitle: String {
        if let root = model.rootURL {
            return "Files — \(FilePathDisplay.compact(root))"
        }
        return "Files"
    }

    // MARK: - Body

    @ViewBuilder
    private var treeBody: some View {
        if model.rootURL == nil {
            emptyNoProject
        } else if model.isRootLoading && model.rootChildren.isEmpty {
            loadingRoot
        } else if let rootError = model.rootError {
            rootErrorView(rootError)
        } else if model.rootChildren.isEmpty {
            emptyFolderMessage
        } else {
            fileList
        }
    }

    private var emptyNoProject: some View {
        VStack(spacing: 6) {
            Text("No project selected.")
                .font(Font.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Text("Files follow the active project's folder.")
                .font(Font.caption)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    private var loadingRoot: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Loading…")
                .font(Font.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func rootErrorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.errorText)
                Text(message)
                    .font(Font.subheadline)
                    .foregroundStyle(Theme.errorText)
            }
            Button("Retry") {
                model.reloadRoot()
            }
            .font(Font.caption)
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accentText)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.errorBackground.opacity(0.35))
    }

    private var emptyFolderMessage: some View {
        Text("Empty folder")
            .font(Font.subheadline)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 12)
            .padding(.top, 8)
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.visibleRows()) { row in
                    rowView(row)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Rows

    @ViewBuilder
    private func rowView(_ row: FileTreeRow) -> some View {
        switch row.kind {
        case .entry:
            entryRow(row)
        case .emptyFolder:
            Text("Empty folder")
                .font(Font.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .padding(.leading, leadingInset(for: row.depth))
                .padding(.trailing, 12)
                .padding(.vertical, 3)
        case .inlineError(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(Font.caption2)
                    .foregroundStyle(Theme.errorText)
                Text(message)
                    .font(Font.subheadline)
                    .foregroundStyle(Theme.errorText)
                    .lineLimit(2)
            }
            .padding(.leading, leadingInset(for: row.depth))
            .padding(.trailing, 12)
            .padding(.vertical, 3)
            .help("Couldn't read this folder")
        }
    }

    private func entryRow(_ row: FileTreeRow) -> some View {
        let node = row.node
        let isSelected = model.selectedURL == node.url
        let isLoading = model.isLoading(node)
        let isExpanded = model.isExpanded(node)

        return HStack(spacing: 6) {
            // Disclosure / spinner / file glyph
            Group {
                if node.isDirectory {
                    if isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(Font.caption2.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    Image(systemName: isSelected ? "diamond.fill" : "diamond")
                        .font(Font.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(width: 14, height: 14)

            Text(node.displayName)
                .font(Font.subheadline)
                .foregroundStyle(Theme.textRow)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.leading, leadingInset(for: row.depth))
        .padding(.trailing, 12)
        .padding(.vertical, 3)
        .background(isSelected ? Theme.fileSelectionFill : Color.clear)
        .contentShape(Rectangle())
        // Double-tap first so it wins over single-tap selection.
        .onTapGesture(count: 2) {
            handleDoubleClick(node)
        }
        .onTapGesture {
            handleTap(node)
        }
        .contextMenu {
            if node.isDirectory {
                Button(isExpanded ? "Collapse" : "Expand") {
                    model.toggleExpand(node)
                }
                Button("Refresh") {
                    model.refresh(node)
                }
            } else {
                Button("Quick Look") {
                    openPreview(for: node)
                }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }
        }
        .accessibilityLabel(node.isDirectory ? "Folder \(node.name)" : "File \(node.name)")
        .accessibilityHint(node.isDirectory ? "Space expands or collapses" : "Space opens preview")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Preview") {
            if !node.isDirectory {
                model.select(node)
                openPreview(for: node)
            }
        }
    }

    private func leadingInset(for depth: Int) -> CGFloat {
        CGFloat(12 + depth * 12)
    }

    // MARK: - Actions

    /// Single click: select (Finder-like). Folders also toggle expand.
    private func handleTap(_ node: FileNode) {
        model.select(node)
        listKeyboardFocused = true
        if node.isDirectory {
            model.toggleExpand(node)
        }
    }

    /// Double-click: open file preview, or toggle folder.
    private func handleDoubleClick(_ node: FileNode) {
        model.select(node)
        listKeyboardFocused = true
        if node.isDirectory {
            model.toggleExpand(node)
        } else {
            openPreview(for: node)
        }
    }

    /// Space / Return — same as Finder Quick Look for files; expand folders.
    private func activateSelected() {
        guard let node = model.selectedNode() else { return }
        if node.isDirectory {
            model.toggleExpand(node)
        } else {
            openPreview(for: node)
        }
    }

    private func openPreview(for node: FileNode) {
        guard !node.isDirectory else { return }
        let request = FilePreviewRequest(url: node.url)
        // Wave 3 wiring: WorkspaceSelection flips the center pane to a preview tab.
        previewPresenter?.presentFilePreview(request)
    }
}

#Preview {
    FileBrowserPaneView(
        model: {
            let model = FileBrowserModel()
            model.setRoot(FileManager.default.homeDirectoryForCurrentUser)
            return model
        }(),
        previewPresenter: nil
    )
    .frame(width: 320, height: 280)
    .preferredColorScheme(.dark)
}

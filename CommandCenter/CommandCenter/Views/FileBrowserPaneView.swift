import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Top-right file browser: FileManager tree with lazy per-directory loading.
///
/// Supports multi-select (⌘/Shift/⌘A), drag-and-drop move between folders,
/// and defaults to the logged-in user's home (`~`) with Desktop / Documents first.
struct FileBrowserPaneView: View {
    @ObservedObject var model: FileBrowserModel
    /// Interim `FilePreviewSession` today; chat controller tomorrow.
    var previewPresenter: FilePreviewPresenting?
    /// Active project's working folder (optional shortcut in the location menu).
    var projectFolderURL: URL? = nil
    var isFocused: Bool = false
    /// When false, omit the "All files" title bar (host provides Files | To-Do tabs).
    var showsChromeHeader: Bool = true

    /// Keyboard focus for Space / Enter / arrows when the Files pane is active.
    @FocusState private var listKeyboardFocused: Bool
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if showsChromeHeader {
                panelHeader
            }
            locationBar
            treeBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.centerBackground)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($listKeyboardFocused)
        .onChange(of: isFocused) { _, focused in
            listKeyboardFocused = focused
        }
        .onAppear {
            if isFocused { listKeyboardFocused = true }
            // Always open at the logged-in user's home (Desktop, Documents, …).
            model.goHome()
        }
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
        .onKeyPress(characters: CharacterSet(charactersIn: "aA")) { press in
            guard isFocused || listKeyboardFocused else { return .ignored }
            guard press.modifiers.contains(.command) else { return .ignored }
            model.selectAllVisible()
            return .handled
        }
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack(spacing: 10) {
            Text("All files")
                .font(Font.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .help(model.rootURL?.path ?? headerTitle)

            Spacer(minLength: 4)

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
            .disabled(model.rootURL == nil)
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

    /// Home / Up / path / Open… so the tree defaults to ~ and can navigate freely.
    private var locationBar: some View {
        HStack(spacing: 6) {
            Button {
                model.goHome()
            } label: {
                Image(systemName: "house.fill")
                    .font(Font.caption.weight(.semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.isAtUserHome ? Theme.accent : Theme.textSecondary)
            .help("Go to home folder (\(FilePathDisplay.compact(FileBrowserModel.userHomeURL)))")
            .disabled(model.isAtUserHome)

            Button {
                model.goUp()
            } label: {
                Image(systemName: "chevron.up")
                    .font(Font.caption.weight(.semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.canGoUp ? Theme.textSecondary : Theme.textTertiary)
            .help("Go to parent folder")
            .disabled(!model.canGoUp)

            Menu {
                ForEach(FileBrowserModel.commonLocations, id: \.url.path) { place in
                    Button(place.title) {
                        model.setRoot(place.url)
                    }
                }
                if let projectFolderURL {
                    Divider()
                    Button("Project Folder") {
                        model.setRoot(projectFolderURL)
                    }
                }
                Divider()
                Button("Choose Folder…") {
                    pickFolder()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(Font.caption2)
                    Text(currentLocationLabel)
                        .font(Font.caption.weight(.medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(Font.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.chipBackground.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .help(model.rootURL?.path ?? "Location")

            Spacer(minLength: 0)
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

    private var currentLocationLabel: String {
        if let root = model.rootURL {
            return FilePathDisplay.compact(root)
        }
        return "~"
    }

    private var headerTitle: String {
        if let root = model.rootURL {
            return "Files — \(FilePathDisplay.compact(root))"
        }
        return "Files"
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Open"
        panel.message = "Choose a folder to show in Files"
        panel.directoryURL = model.rootURL ?? FileBrowserModel.userHomeURL
        if panel.runModal() == .OK, let url = panel.url {
            model.setRoot(url)
        }
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
        VStack(spacing: 8) {
            Text("No folder open")
                .font(Font.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Text("Defaults to your home folder (~).")
                .font(Font.caption)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
            Button("Go to Home") {
                model.goHome()
            }
            .font(Font.caption)
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accentText)
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
        let selected = model.isSelected(node)
        return entryRowContent(row: row, node: node, isSelected: selected)
            .onTapGesture(count: 2) { handleDoubleClick(node) }
            .onTapGesture { handleTap(node) }
            .onDrag { dragProvider(for: node) }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                let dest = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
                return handleDrop(providers, onto: dest)
            }
            .contextMenu { entryContextMenu(node: node) }
            .accessibilityLabel(node.isDirectory ? "Folder \(node.name)" : "File \(node.name)")
            .accessibilityHint(node.isDirectory ? "Space expands or collapses" : "Space opens preview")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityAction(named: "Preview") {
                if !node.isDirectory {
                    model.select(node)
                    openPreview(for: node)
                }
            }
    }

    private func entryRowContent(row: FileTreeRow, node: FileNode, isSelected: Bool) -> some View {
        let isLoading = model.isLoading(node)
        let isExpanded = model.isExpanded(node)
        return HStack(spacing: 6) {
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
    }

    @ViewBuilder
    private func entryContextMenu(node: FileNode) -> some View {
        if node.isDirectory {
            Button("Open as Root") { model.setRoot(node.url) }
            Button(model.isExpanded(node) ? "Collapse" : "Expand") { model.toggleExpand(node) }
            Button("Refresh") { model.refresh(node) }
        } else {
            Button("Quick Look") { openPreview(for: node) }
        }
        if model.selectedURLs.count > 1 {
            Divider()
            Button("Reveal \(model.selectedURLs.count) Items in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(model.selectedURLs)
            }
        }
        Divider()
        Button("Go to Home") { model.goHome() }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        }
    }

    private func dragProvider(for node: FileNode) -> NSItemProvider {
        // Ensure the dragged row is selected so multi-select drops include peers.
        if !model.isSelected(node) {
            model.select(node)
        }
        let urls = model.selectedURLs.isEmpty ? [node.url] : model.selectedURLs
        // Primary file URL for Finder / system; multi-select expanded on drop.
        return NSItemProvider(object: (urls.first ?? node.url) as NSURL)
    }

    private func leadingInset(for depth: Int) -> CGFloat {
        CGFloat(12 + depth * 12)
    }

    // MARK: - Actions

    /// Single click: select. ⌘ toggles multi-select; Shift ranges. Folders expand on plain click.
    private func handleTap(_ node: FileNode) {
        listKeyboardFocused = true
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) {
            model.toggleSelect(node)
        } else if flags.contains(.shift) {
            model.selectRange(to: node)
        } else {
            model.select(node)
            if node.isDirectory {
                model.toggleExpand(node)
            }
        }
    }

    /// Double-click: open file preview, or open folder as the new tree root.
    private func handleDoubleClick(_ node: FileNode) {
        model.select(node)
        listKeyboardFocused = true
        if node.isDirectory {
            model.setRoot(node.url)
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
        previewPresenter?.presentFilePreview(request)
    }

    /// Drop onto the pane background → selection folder or root.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        handleDrop(providers, onto: nil)
    }

    /// Drop onto a folder (move within tree / copy from Finder).
    private func handleDrop(_ providers: [NSItemProvider], onto destination: URL?) -> Bool {
        var any = false
        let group = DispatchGroup()
        let lock = NSLock()
        var collected: [URL] = []
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            any = true
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                } else if let s = item as? String {
                    url = URL(fileURLWithPath: s)
                } else {
                    url = nil
                }
                if let url {
                    lock.lock()
                    collected.append(url.standardizedFileURL)
                    lock.unlock()
                }
            }
        }
        group.notify(queue: .main) {
            lock.lock()
            var urls = collected
            lock.unlock()
            guard !urls.isEmpty else { return }
            // Multi-select drag: onDrag only carries one URL — expand to full selection
            // when the dragged item is part of the current multi-select.
            if model.selectedURLs.count > 1,
               urls.contains(where: { model.selectedPaths.contains($0.path) }) {
                urls = model.selectedURLs
            }
            do {
                _ = try model.handleFileDrop(urls, onto: destination)
            } catch {
                // Drop highlight is the only feedback.
            }
        }
        return any
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

import AppKit
import SwiftData
import SwiftUI

/// Project creation flow (T11): folder picker + "start empty" fallback.
///
/// - Choose any existing directory → Project name defaults to folder name (editable).
/// - Or start empty → creates a fresh folder under `~/Projects/<name>`.
struct ProjectCreationSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var onCreated: (WorkspaceProject) -> Void

    @State private var name: String = ""
    @State private var folderPath: String?
    @State private var mode: CreationMode = .empty
    @State private var errorMessage: String?

    private enum CreationMode {
        case empty
        case existingFolder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Project")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Text("Group chats and files by what you're working on. Pick an existing folder, or start empty under ~/Projects.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.6)

                TextField("Project name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.elevatedSurface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Theme.borderStructural, lineWidth: 1)
                            )
                    )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Working folder")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.6)

                HStack(spacing: 8) {
                    modeButton(
                        title: "Choose folder…",
                        isSelected: mode == .existingFolder
                    ) {
                        pickFolder()
                    }

                    modeButton(
                        title: "Start empty",
                        isSelected: mode == .empty
                    ) {
                        mode = .empty
                        folderPath = nil
                    }
                }

                Text(folderSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.errorText)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.errorBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Theme.errorBorder, lineWidth: 1)
                            )
                    )
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                Button("Create Project") { create() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textOnAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Theme.accent)
                    )
                    .disabled(!canCreate)
                    .opacity(canCreate ? 1 : 0.5)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(Theme.appBackground)
    }

    private var canCreate: Bool {
        switch mode {
        case .empty:
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .existingFolder:
            return folderPath != nil
        }
    }

    private var folderSummary: String {
        switch mode {
        case .empty:
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let leaf = n.isEmpty ? "<name>" : n
            return "Will create ~/Projects/\(leaf)"
        case .existingFolder:
            if let folderPath {
                return folderPath
            }
            return "No folder selected"
        }
    }

    private func modeButton(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? Theme.accentText : Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.chipBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(
                                    isSelected ? Theme.accent : Theme.borderStructural,
                                    lineWidth: 1
                                )
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the working folder for this Project"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        mode = .existingFolder
        folderPath = url.path
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = url.lastPathComponent
        }
    }

    private func create() {
        errorMessage = nil
        do {
            let project: WorkspaceProject
            switch mode {
            case .empty:
                project = try ProjectFactory.createEmpty(named: name, in: modelContext)
            case .existingFolder:
                guard let folderPath else {
                    errorMessage = "Choose a folder first."
                    return
                }
                project = ProjectFactory.createFromExistingFolder(
                    url: URL(fileURLWithPath: folderPath),
                    name: name,
                    in: modelContext
                )
            }
            try modelContext.save()
            onCreated(project)
            dismiss()
        } catch {
            errorMessage = "Couldn't create project: \(error.localizedDescription)"
        }
    }
}

#Preview {
    ProjectCreationSheet(onCreated: { _ in })
        .modelContainer(for: [
            WorkspaceProject.self,
            Agent.self,
            ChatThread.self,
            Message.self,
        ], inMemory: true)
}

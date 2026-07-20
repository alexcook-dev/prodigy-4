import SwiftData
import SwiftUI

/// Create a reusable Agent persona (system prompt + name).
/// Conversations with the Agent are scoped per-Project when selected.
struct AgentCreationSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var onCreated: (Agent) -> Void

    @State private var name: String = ""
    @State private var systemPrompt: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Agent")
                .font(Font.headline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)

            Text("Reusable personas — an editor, a researcher, a planner. The system prompt is shared; each Project keeps its own conversation with this Agent.")
                .font(Font.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Name")
                TextField("e.g. Research Assistant", text: $name)
                    .textFieldStyle(.plain)
                    .font(Font.callout)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(fieldBackground)
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("System prompt")
                TextEditor(text: $systemPrompt)
                    .font(Font.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120, maxHeight: 200)
                    .padding(8)
                    .background(fieldBackground)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                Button("Create Agent") { create() }
                    .buttonStyle(.plain)
                    .font(Font.callout.weight(.medium))
                    .foregroundStyle(Theme.textOnAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Theme.accent)
                    )
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1
                    )
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(Theme.appBackground)
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(Font.caption.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            .textCase(.uppercase)
            .tracking(0.6)
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Theme.elevatedSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.borderStructural, lineWidth: 1)
            )
    }

    private func create() {
        let agent = AgentFactory.create(
            name: name,
            systemPrompt: systemPrompt.isEmpty
                ? "You are a helpful assistant."
                : systemPrompt,
            in: modelContext
        )
        try? modelContext.save()
        onCreated(agent)
        dismiss()
    }
}

#Preview {
    AgentCreationSheet(onCreated: { _ in })
        .modelContainer(for: [
            WorkspaceProject.self,
            Agent.self,
            ChatThread.self,
            Message.self,
        ], inMemory: true)
}

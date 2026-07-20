import AppKit
import SwiftUI

/// Compact Apple Reminders (To-Do) pane for the top-right column tab.
///
/// Full CRUD inside Prodigy: add, complete, edit (title/notes/due/list), delete.
struct AppleRemindersPaneView: View {
    @ObservedObject var reminders: AppleRemindersService
    var isFocused: Bool = false

    @FocusState private var draftFocused: Bool
    /// Item being edited in the sheet (`nil` = sheet dismissed).
    @State private var editingItem: AppleReminderItem?
    /// Inline title edit for a single row (quick rename).
    @State private var inlineEditID: String?
    @State private var inlineEditTitle: String = ""
    @FocusState private var inlineFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let error = reminders.errorMessage, reminders.reminders.isEmpty, !reminders.isLoading {
                permissionOrError(error)
            } else {
                listFilterBar
                addBar
                remindersList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.centerBackground)
        .task {
            await reminders.refresh()
        }
        .onChange(of: isFocused) { _, focused in
            if focused, inlineEditID == nil { draftFocused = true }
        }
        .sheet(item: $editingItem) { item in
            TodoEditSheet(
                item: item,
                lists: reminders.lists,
                onSave: { title, notes, due, listID in
                    Task {
                        let ok = await reminders.updateReminder(
                            item,
                            title: title,
                            notes: notes,
                            dueDate: .some(due),
                            listID: listID
                        )
                        if ok { editingItem = nil }
                    }
                },
                onDelete: {
                    Task {
                        _ = await reminders.deleteReminder(item)
                        editingItem = nil
                    }
                },
                onCancel: { editingItem = nil }
            )
        }
    }

    // MARK: - Filter

    private var listFilterBar: some View {
        HStack(spacing: 6) {
            Picker("List", selection: $reminders.selectedListID) {
                Text("All lists").tag(String?.none)
                ForEach(reminders.lists) { list in
                    Text(list.title).tag(Optional(list.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)

            if reminders.isLoading {
                ProgressView()
                    .controlSize(.mini)
            }

            Button {
                Task { await reminders.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(Font.caption.weight(.medium))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Refresh Reminders")
            .disabled(reminders.isLoading)

            Button {
                openRemindersApp()
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(Font.caption.weight(.medium))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Reminders.app")
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

    // MARK: - Add

    private var addBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .font(Font.caption)
                .foregroundStyle(Theme.accent)

            TextField("New to-do", text: $reminders.draftTitle)
                .textFieldStyle(.plain)
                .font(Font.subheadline)
                .focused($draftFocused)
                .onSubmit {
                    Task {
                        _ = await reminders.addReminder(title: reminders.draftTitle)
                        draftFocused = true
                    }
                }

            if !reminders.draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Add") {
                    Task {
                        _ = await reminders.addReminder(title: reminders.draftTitle)
                        draftFocused = true
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.elevatedSurface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.borderHairline)
                .frame(height: 1)
        }
    }

    // MARK: - List

    private var remindersList: some View {
        Group {
            if reminders.visibleReminders.isEmpty && !reminders.isLoading {
                VStack(spacing: 10) {
                    Image(systemName: "checklist")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(Theme.textTertiary)
                    Text("No open to-dos")
                        .font(Font.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                    Text("Add one above — edit or delete anytime.")
                        .font(Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(reminders.visibleReminders) { item in
                            reminderRow(item)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let error = reminders.errorMessage, !reminders.reminders.isEmpty {
                Text(error)
                    .font(Font.caption2)
                    .foregroundStyle(Theme.errorText)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(Theme.errorBackground)
            }
        }
    }

    private func reminderRow(_ item: AppleReminderItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                Task {
                    await reminders.setCompleted(item, completed: true)
                }
            } label: {
                Image(systemName: "circle")
                    .font(Font.body)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Mark complete")
            .disabled(inlineEditID == item.id)

            VStack(alignment: .leading, spacing: 2) {
                if inlineEditID == item.id {
                    TextField("Title", text: $inlineEditTitle)
                        .textFieldStyle(.plain)
                        .font(Font.subheadline)
                        .focused($inlineFieldFocused)
                        .onSubmit { commitInlineEdit(item) }
                        .onExitCommand { cancelInlineEdit() }
                } else {
                    Text(item.title)
                        .font(Font.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            beginInlineEdit(item)
                        }

                    HStack(spacing: 6) {
                        if let due = item.dueDate {
                            Text(dueLabel(due))
                                .font(Font.caption2)
                                .foregroundStyle(due < Date() ? Theme.errorText : Theme.textTertiary)
                        }
                        if !item.notes.isEmpty {
                            Text(item.notes)
                                .font(Font.caption2)
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                        if reminders.selectedListID == nil {
                            Text(item.listName)
                                .font(Font.caption2)
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            Spacer(minLength: 4)

            if inlineEditID == item.id {
                Button("Save") { commitInlineEdit(item) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                Button {
                    cancelInlineEdit()
                } label: {
                    Image(systemName: "xmark")
                        .font(Font.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Cancel")
            } else {
                Button {
                    editingItem = item
                } label: {
                    Image(systemName: "pencil")
                        .font(Font.caption.weight(.medium))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Edit to-do")

                Button {
                    Task { _ = await reminders.deleteReminder(item) }
                } label: {
                    Image(systemName: "trash")
                        .font(Font.caption.weight(.medium))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete to-do")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Edit…") {
                editingItem = item
            }
            Button("Rename") {
                beginInlineEdit(item)
            }
            Button("Mark Complete") {
                Task { await reminders.setCompleted(item, completed: true) }
            }
            Divider()
            Button("Delete", role: .destructive) {
                Task { _ = await reminders.deleteReminder(item) }
            }
            Divider()
            Button("Open in Reminders") {
                openRemindersApp()
            }
        }
    }

    // MARK: - Inline edit

    private func beginInlineEdit(_ item: AppleReminderItem) {
        inlineEditID = item.id
        inlineEditTitle = item.title
        DispatchQueue.main.async {
            inlineFieldFocused = true
        }
    }

    private func cancelInlineEdit() {
        inlineEditID = nil
        inlineEditTitle = ""
        inlineFieldFocused = false
    }

    private func commitInlineEdit(_ item: AppleReminderItem) {
        let title = inlineEditTitle
        cancelInlineEdit()
        Task {
            _ = await reminders.updateReminder(item, title: title)
        }
    }

    private func dueLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return "Today"
        }
        if cal.isDateInTomorrow(date) {
            return "Tomorrow"
        }
        if cal.isDateInYesterday(date) {
            return "Yesterday"
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func permissionOrError(_ error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checklist")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("Reminders")
                .font(Font.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(error)
                .font(Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
            HStack(spacing: 8) {
                Button("Refresh") {
                    Task { await reminders.refresh() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    private func openRemindersApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Reminders.app"))
        }
    }
}

// MARK: - Edit sheet

private struct TodoEditSheet: View {
    let item: AppleReminderItem
    let lists: [AppleReminderList]
    var onSave: (_ title: String, _ notes: String, _ due: Date?, _ listID: String?) -> Void
    var onDelete: () -> Void
    var onCancel: () -> Void

    @State private var title: String = ""
    @State private var notes: String = ""
    @State private var hasDueDate: Bool = false
    @State private var dueDate: Date = Date()
    @State private var listID: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit To-Do")
                .font(Font.headline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Title")
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(Font.callout)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(fieldChrome)
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Notes")
                TextField("Notes (optional)", text: $notes, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Font.callout)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(3...6)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(fieldChrome)
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("List")
                Picker("List", selection: $listID) {
                    ForEach(lists) { list in
                        Text(list.title).tag(list.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Due date", isOn: $hasDueDate)
                    .toggleStyle(.checkbox)
                    .font(Font.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                if hasDueDate {
                    DatePicker(
                        "Due",
                        selection: $dueDate,
                        displayedComponents: [.date]
                    )
                    .labelsHidden()
                    .datePickerStyle(.compact)
                }
            }

            HStack {
                Button("Delete", role: .destructive, action: onDelete)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.errorText)

                Spacer()

                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                Button("Save") {
                    onSave(
                        title,
                        notes,
                        hasDueDate ? dueDate : nil,
                        listID.isEmpty ? nil : listID
                    )
                }
                .buttonStyle(.plain)
                .font(Font.callout.weight(.medium))
                .foregroundStyle(Theme.textOnAccent)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.accent)
                )
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(Theme.appBackground)
        .onAppear {
            title = item.title
            notes = item.notes
            hasDueDate = item.dueDate != nil
            dueDate = item.dueDate ?? Date()
            listID = item.listID
            if listID.isEmpty, let first = lists.first {
                listID = first.id
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(Font.caption.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            .textCase(.uppercase)
            .tracking(0.6)
    }

    private var fieldChrome: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Theme.elevatedSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.borderStructural, lineWidth: 1)
            )
    }
}

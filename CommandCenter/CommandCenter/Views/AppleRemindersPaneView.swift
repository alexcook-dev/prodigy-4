import AppKit
import SwiftUI

/// Compact Apple Reminders (To-Do) pane for the top-right column tab.
struct AppleRemindersPaneView: View {
    @ObservedObject var reminders: AppleRemindersService
    var isFocused: Bool = false

    @FocusState private var draftFocused: Bool

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
            if focused { draftFocused = true }
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
                    }
                }

            if !reminders.draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Add") {
                    Task {
                        _ = await reminders.addReminder(title: reminders.draftTitle)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
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
                    Text("Add one above, or open Reminders.app.")
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

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(Font.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    if let due = item.dueDate {
                        Text(dueLabel(due))
                            .font(Font.caption2)
                            .foregroundStyle(due < Date() ? Theme.errorText : Theme.textTertiary)
                    }
                    if reminders.selectedListID == nil {
                        Text(item.listName)
                            .font(Font.caption2)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Mark Complete") {
                Task { await reminders.setCompleted(item, completed: true) }
            }
            Button("Open in Reminders") {
                openRemindersApp()
            }
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

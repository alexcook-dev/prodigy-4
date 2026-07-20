import EventKit
import Foundation

// MARK: - Models

struct AppleReminderItem: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var notes: String
    var isCompleted: Bool
    var dueDate: Date?
    var priority: Int
    var listName: String
    var listID: String
}

struct AppleReminderList: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
}

// MARK: - Service

/// Native **Apple Reminders** (To-Do) data via EventKit — same store as Reminders.app.
@MainActor
final class AppleRemindersService: ObservableObject {
    static let shared = AppleRemindersService()

    @Published var reminders: [AppleReminderItem] = []
    @Published var lists: [AppleReminderList] = []
    /// `nil` = all lists.
    @Published var selectedListID: String?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var authorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var draftTitle: String = ""

    private let store = EKEventStore()

    var incompleteReminders: [AppleReminderItem] {
        reminders.filter { !$0.isCompleted }
    }

    var visibleReminders: [AppleReminderItem] {
        let base = incompleteReminders
        guard let selectedListID else { return base }
        return base.filter { $0.listID == selectedListID }
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        authorizationStatus = EKEventStore.authorizationStatus(for: .reminder)

        do {
            try await requestAccessIfNeeded()
            authorizationStatus = EKEventStore.authorizationStatus(for: .reminder)

            let calendars = store.calendars(for: .reminder)
            lists = calendars
                .map { AppleReminderList(id: $0.calendarIdentifier, title: $0.title) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

            if let selectedListID,
               !lists.contains(where: { $0.id == selectedListID }) {
                self.selectedListID = nil
            }

            let predicate = store.predicateForIncompleteReminders(
                withDueDateStarting: nil,
                ending: nil,
                calendars: nil
            )

            let ekReminders: [EKReminder] = try await withCheckedThrowingContinuation { cont in
                store.fetchReminders(matching: predicate) { results in
                    cont.resume(returning: results ?? [])
                }
            }

            reminders = ekReminders
                .map { r in
                    let due = r.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
                    return AppleReminderItem(
                        id: r.calendarItemIdentifier,
                        title: r.title?.isEmpty == false ? r.title! : "(no title)",
                        notes: r.notes ?? "",
                        isCompleted: r.isCompleted,
                        dueDate: due,
                        priority: r.priority,
                        listName: r.calendar?.title ?? "Reminders",
                        listID: r.calendar?.calendarIdentifier ?? ""
                    )
                }
                .sorted { lhs, rhs in
                    switch (lhs.dueDate, rhs.dueDate) {
                    case let (l?, r?):
                        if l != r { return l < r }
                    case (_?, nil):
                        return true
                    case (nil, _?):
                        return false
                    case (nil, nil):
                        break
                    }
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
        } catch {
            errorMessage = error.localizedDescription
            reminders = []
            lists = []
        }
    }

    /// Toggle completed and persist to Reminders.app.
    func setCompleted(_ item: AppleReminderItem, completed: Bool) async {
        errorMessage = nil
        do {
            try await requestAccessIfNeeded()
            guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else {
                errorMessage = "Reminder not found."
                await refresh()
                return
            }
            reminder.isCompleted = completed
            if completed {
                reminder.completionDate = Date()
            } else {
                reminder.completionDate = nil
            }
            try store.save(reminder, commit: true)
            if let idx = reminders.firstIndex(where: { $0.id == item.id }) {
                reminders[idx].isCompleted = completed
            }
            if completed {
                reminders.removeAll { $0.id == item.id }
            }
        } catch {
            errorMessage = error.localizedDescription
            await refresh()
        }
    }

    /// Create a new incomplete reminder in the selected (or default) list.
    @discardableResult
    func addReminder(title: String) async -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        errorMessage = nil
        do {
            try await requestAccessIfNeeded()
            let reminder = EKReminder(eventStore: store)
            reminder.title = trimmed
            reminder.calendar = preferredCalendar()
            try store.save(reminder, commit: true)
            draftTitle = ""
            await refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func preferredCalendar() -> EKCalendar {
        if let selectedListID,
           let match = store.calendars(for: .reminder).first(where: {
               $0.calendarIdentifier == selectedListID
           }) {
            return match
        }
        return store.defaultCalendarForNewReminders()
            ?? store.calendars(for: .reminder).first
            ?? EKCalendar(for: .reminder, eventStore: store)
    }

    private func requestAccessIfNeeded() async throws {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .fullAccess, .authorized:
            return
        case .denied, .restricted:
            throw AppleRemindersError.denied
        case .writeOnly:
            throw AppleRemindersError.denied
        case .notDetermined:
            break
        @unknown default:
            break
        }

        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = try await store.requestFullAccessToReminders()
        } else {
            granted = try await withCheckedThrowingContinuation { cont in
                store.requestAccess(to: .reminder) { ok, error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: ok)
                    }
                }
            }
        }
        if !granted {
            throw AppleRemindersError.denied
        }
    }
}

enum AppleRemindersError: LocalizedError {
    case denied

    var errorDescription: String? {
        switch self {
        case .denied:
            return "Reminders access denied. System Settings → Privacy & Security → Reminders → enable Prodigy, then refresh."
        }
    }
}

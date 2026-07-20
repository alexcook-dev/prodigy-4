import EventKit
import Foundation

// MARK: - Models

struct AppleCalendarEvent: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var location: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var calendarName: String
    var notes: String
    var url: URL?
}

// MARK: - Service

/// Native **Apple Calendar** data via EventKit (same store as Calendar.app).
@MainActor
final class AppleCalendarService: ObservableObject {
    static let shared = AppleCalendarService()

    @Published var events: [AppleCalendarEvent] = []
    @Published var selectedID: String?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var authorizationStatus: EKAuthorizationStatus = .notDetermined

    private let store = EKEventStore()

    var selectedEvent: AppleCalendarEvent? {
        events.first { $0.id == selectedID }
    }

    func refresh(daysAhead: Int = 14) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        authorizationStatus = EKEventStore.authorizationStatus(for: .event)

        do {
            try await requestAccessIfNeeded()
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)

            let start = Date()
            let end = Calendar.current.date(byAdding: .day, value: daysAhead, to: start) ?? start
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            let ekEvents = store.events(matching: predicate)
                .sorted { $0.startDate < $1.startDate }

            events = ekEvents.map { e in
                AppleCalendarEvent(
                    id: e.eventIdentifier ?? UUID().uuidString,
                    title: e.title?.isEmpty == false ? e.title! : "(no title)",
                    location: e.location ?? "",
                    start: e.startDate,
                    end: e.endDate,
                    isAllDay: e.isAllDay,
                    calendarName: e.calendar?.title ?? "Calendar",
                    notes: e.notes ?? "",
                    url: e.url
                )
            }
            if selectedID == nil || !events.contains(where: { $0.id == selectedID }) {
                selectedID = events.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
            events = []
        }
    }

    private func requestAccessIfNeeded() async throws {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess, .authorized:
            return
        case .denied, .restricted:
            throw AppleCalendarError.denied
        case .writeOnly:
            // Need read for listing events.
            throw AppleCalendarError.denied
        case .notDetermined:
            break
        @unknown default:
            break
        }

        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = try await store.requestFullAccessToEvents()
        } else {
            granted = try await withCheckedThrowingContinuation { cont in
                store.requestAccess(to: .event) { ok, error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: ok)
                    }
                }
            }
        }
        if !granted {
            throw AppleCalendarError.denied
        }
    }
}

enum AppleCalendarError: LocalizedError {
    case denied

    var errorDescription: String? {
        switch self {
        case .denied:
            return "Calendar access denied. System Settings → Privacy & Security → Calendars → enable Prodigy, then refresh."
        }
    }
}

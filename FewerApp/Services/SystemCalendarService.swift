import AppKit
import Combine
import EventKit
import FewerCore
import Foundation

enum SystemCalendarAuthorizationState: Equatable {
    case notDetermined
    case fullAccess
    case writeOnly
    case denied
    case restricted
}

@MainActor
final class SystemCalendarService: NSObject, ObservableObject {
    static let shared = SystemCalendarService()

    @Published private(set) var authorizationState: SystemCalendarAuthorizationState
    @Published private(set) var reminderAuthorizationState: SystemCalendarAuthorizationState
    @Published private(set) var events: [CalendarEventItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isRequestingAccess = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var changeRevision = 0

    private let eventKitWorker = EventKitWorker()
    private var eventCache = CalendarEventCache()
    private var eventDayIndex = CalendarEventDayIndex()
    private var coalescedLoadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var lastCalendarKey: String = ""

    private override init() {
        authorizationState = Self.authorizationState(for: .event)
        reminderAuthorizationState = Self.authorizationState(for: .reminder)
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(eventStoreDidChange),
            name: .EKEventStoreChanged,
            object: nil
        )
    }

    func requestFullAccess() async {
        let shouldRequestEvents = authorizationState == .notDetermined || authorizationState == .writeOnly
        let shouldRequestReminders = reminderAuthorizationState == .notDetermined
        guard shouldRequestEvents || shouldRequestReminders else {
            return
        }

        isRequestingAccess = true
        errorMessage = nil
        defer { isRequestingAccess = false }

        var accessErrors: [Error] = []
        if shouldRequestEvents {
            do {
                _ = try await eventKitWorker.requestFullAccessToEvents()
            } catch {
                accessErrors.append(error)
            }
        }
        if shouldRequestReminders {
            do {
                _ = try await eventKitWorker.requestFullAccessToReminders()
            } catch {
                accessErrors.append(error)
            }
        }
        let previousEventAuth = authorizationState
        let previousReminderAuth = reminderAuthorizationState
        refreshAuthorizationState()
        if authorizationState != previousEventAuth || reminderAuthorizationState != previousReminderAuth {
            eventCache.clear()
        }
        errorMessage = accessErrors.first?.localizedDescription
    }

    func loadEvents(from firstVisibleDate: Date, through lastVisibleDate: Date, calendar: Calendar) {
        refreshAuthorizationState()

        let calendarKey = "\(calendar.locale?.identifier ?? "")-\(calendar.timeZone.identifier)-\(calendar.firstWeekday)"
        if calendarKey != lastCalendarKey {
            lastCalendarKey = calendarKey
            eventCache.clear()
            eventDayIndex = CalendarEventDayIndex()
        }

        guard let endDate = calendar.date(byAdding: .day, value: 1, to: lastVisibleDate),
              authorizationState == .fullAccess || reminderAuthorizationState == .fullAccess else {
            events = []
            eventDayIndex = CalendarEventDayIndex()
            isLoading = false
            return
        }

        let visibleRange = DateInterval(start: firstVisibleDate, end: endDate)
        if let cached = eventCache.events(for: visibleRange) {
            publish(cached, visibleRange: visibleRange, calendar: calendar)
            isLoading = false
            return
        }

        coalescedLoadTask?.cancel()
        coalescedLoadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.performLoad(visibleRange: visibleRange, calendar: calendar)
        }
        isLoading = true
    }

    private func performLoad(visibleRange: DateInterval, calendar: Calendar) async {
        loadGeneration &+= 1
        let generation = loadGeneration

        var eventItems: [CalendarEventItem] = []
        if authorizationState == .fullAccess {
            eventItems = await eventKitWorker.fetchEvents(in: visibleRange)
            guard generation == loadGeneration else { return }
        }

        publish(Self.sorted(eventItems), visibleRange: visibleRange, calendar: calendar)

        guard reminderAuthorizationState == .fullAccess else {
            isLoading = false
            eventCache.insert(events, for: visibleRange)
            return
        }

        let reminderItems = await eventKitWorker.fetchReminders(in: visibleRange, calendar: calendar)
        guard generation == loadGeneration else { return }

        let combined = Self.sorted(eventItems + reminderItems)
        publish(combined, visibleRange: visibleRange, calendar: calendar)
        isLoading = false
        eventCache.insert(combined, for: visibleRange)
    }

    func events(on date: Date, calendar: Calendar) -> [CalendarEventItem] {
        eventDayIndex.events(on: date, calendar: calendar)
    }

    func openPrivacySettings() {
        let privacyPane = authorizationState == .fullAccess ? "Privacy_Reminders" : "Privacy_Calendars"
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(privacyPane)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func refreshAuthorizationState() {
        authorizationState = Self.authorizationState(for: .event)
        reminderAuthorizationState = Self.authorizationState(for: .reminder)
    }

    @objc private func eventStoreDidChange() {
        refreshAuthorizationState()
        eventCache.clear()
        eventDayIndex = CalendarEventDayIndex()
        changeRevision &+= 1
    }

    private func publish(_ items: [CalendarEventItem], visibleRange: DateInterval, calendar: Calendar) {
        events = items
        eventDayIndex = CalendarEventDayIndex(
            events: items,
            firstDate: visibleRange.start,
            lastDate: visibleRange.end.addingTimeInterval(-1),
            calendar: calendar
        )
    }

    private static func authorizationState(for entityType: EKEntityType) -> SystemCalendarAuthorizationState {
        switch EKEventStore.authorizationStatus(for: entityType) {
        case .notDetermined:
            return .notDetermined
        case .fullAccess:
            return .fullAccess
        case .writeOnly:
            return .writeOnly
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .denied
        }
    }

    private static func sorted(_ items: [CalendarEventItem]) -> [CalendarEventItem] {
        items.sorted {
            if $0.isAllDay != $1.isAllDay {
                return $0.isAllDay
            }
            if $0.startDate != $1.startDate {
                return $0.startDate < $1.startDate
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}

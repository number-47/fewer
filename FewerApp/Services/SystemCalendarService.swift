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

    private let eventStore = EKEventStore()
    private var reminderFetchIdentifier: Any?
    private var loadGeneration = 0

    private override init() {
        authorizationState = Self.authorizationState(for: .event)
        reminderAuthorizationState = Self.authorizationState(for: .reminder)
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(eventStoreDidChange),
            name: .EKEventStoreChanged,
            object: eventStore
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
                _ = try await eventStore.requestFullAccessToEvents()
            } catch {
                accessErrors.append(error)
            }
        }
        if shouldRequestReminders {
            do {
                _ = try await eventStore.requestFullAccessToReminders()
            } catch {
                accessErrors.append(error)
            }
        }
        refreshAuthorizationState()
        errorMessage = accessErrors.first?.localizedDescription
    }

    func loadEvents(from firstVisibleDate: Date, through lastVisibleDate: Date, calendar: Calendar) {
        refreshAuthorizationState()
        loadGeneration &+= 1
        let generation = loadGeneration
        if let reminderFetchIdentifier {
            eventStore.cancelFetchRequest(reminderFetchIdentifier)
            self.reminderFetchIdentifier = nil
        }

        guard let endDate = calendar.date(byAdding: .day, value: 1, to: lastVisibleDate),
              authorizationState == .fullAccess || reminderAuthorizationState == .fullAccess else {
            events = []
            isLoading = false
            return
        }

        isLoading = true
        errorMessage = nil

        let eventItems: [CalendarEventItem]
        if authorizationState == .fullAccess {
            let predicate = eventStore.predicateForEvents(
                withStart: firstVisibleDate,
                end: endDate,
                calendars: nil
            )
            eventItems = eventStore.events(matching: predicate)
                .map(Self.makeEventItem)
        } else {
            eventItems = []
        }

        events = Self.sorted(eventItems)
        guard reminderAuthorizationState == .fullAccess else {
            isLoading = false
            return
        }

        let reminderPredicate = eventStore.predicateForReminders(in: nil)
        let visibleRange = DateInterval(start: firstVisibleDate, end: endDate)
        reminderFetchIdentifier = eventStore.fetchReminders(matching: reminderPredicate) { [weak self] reminders in
            Task { @MainActor [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                let reminderItems = (reminders ?? []).flatMap {
                    Self.makeReminderItems(from: $0, in: visibleRange, calendar: calendar)
                }
                self.events = Self.sorted(eventItems + reminderItems)
                self.reminderFetchIdentifier = nil
                self.isLoading = false
            }
        }
    }

    func events(on date: Date, calendar: Calendar) -> [CalendarEventItem] {
        events.filter { $0.overlaps(dayContaining: date, calendar: calendar) }
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
        changeRevision &+= 1
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

    private static func makeEventItem(from event: EKEvent) -> CalendarEventItem {
        let baseIdentifier = event.eventIdentifier ?? event.calendarItemIdentifier
        let identifier = "\(baseIdentifier)-\(event.startDate.timeIntervalSinceReferenceDate)"
        let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return CalendarEventItem(
            id: identifier,
            title: title,
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            calendarTitle: event.calendar.title,
            isSubscription: event.calendar.type == .subscription,
            color: colorComponents(from: event.calendar.cgColor)
        )
    }

    private static func makeReminderItems(
        from reminder: EKReminder,
        in visibleRange: DateInterval,
        calendar: Calendar
    ) -> [CalendarEventItem] {
        guard var components = reminder.dueDateComponents ?? reminder.startDateComponents else {
            return []
        }
        components.calendar = calendar
        if components.timeZone == nil {
            components.timeZone = calendar.timeZone
        }
        guard let anchorDate = components.date else { return [] }

        let isAllDay = components.hour == nil && components.minute == nil && components.second == nil
        let recurrenceRules = (reminder.recurrenceRules ?? []).compactMap(Self.makeRecurrenceRule)
        let occurrenceDates: [Date]
        if reminder.isCompleted || recurrenceRules.isEmpty {
            occurrenceDates = visibleRange.contains(anchorDate) ? [anchorDate] : []
        } else {
            occurrenceDates = recurrenceRules.flatMap {
                ReminderRecurrence.occurrenceDates(
                    anchor: anchorDate,
                    rule: $0,
                    in: visibleRange,
                    calendar: calendar
                )
            }
        }

        var seenDates = Set<Date>()
        return occurrenceDates.compactMap { startDate in
            guard seenDates.insert(startDate).inserted else { return nil }
            return makeReminderItem(
                from: reminder,
                startDate: startDate,
                isAllDay: isAllDay,
                calendar: calendar
            )
        }
    }

    private static func makeReminderItem(
        from reminder: EKReminder,
        startDate: Date,
        isAllDay: Bool,
        calendar: Calendar
    ) -> CalendarEventItem {
        let endDate = calendar.date(
            byAdding: isAllDay ? .day : .minute,
            value: 1,
            to: startDate
        ) ?? startDate.addingTimeInterval(isAllDay ? 86_400 : 60)
        let title = reminder.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let identifier = "reminder-\(reminder.calendarItemIdentifier)-\(startDate.timeIntervalSinceReferenceDate)"

        return CalendarEventItem(
            id: identifier,
            title: title,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            calendarTitle: reminder.calendar.title,
            isSubscription: false,
            color: colorComponents(from: reminder.calendar.cgColor),
            kind: .reminder,
            isCompleted: reminder.isCompleted
        )
    }

    private static func makeRecurrenceRule(from rule: EKRecurrenceRule) -> ReminderRecurrenceRule? {
        let frequency: ReminderRecurrenceFrequency
        switch rule.frequency {
        case .daily:
            frequency = .daily
        case .weekly:
            frequency = .weekly
        case .monthly:
            frequency = .monthly
        case .yearly:
            frequency = .yearly
        @unknown default:
            return nil
        }

        let weekdays = (rule.daysOfTheWeek ?? []).map {
            ReminderRecurrenceWeekday(
                weekday: $0.dayOfTheWeek.rawValue,
                ordinal: $0.weekNumber
            )
        }
        return ReminderRecurrenceRule(
            frequency: frequency,
            interval: rule.interval,
            weekdays: weekdays,
            monthDays: (rule.daysOfTheMonth ?? []).map(\.intValue),
            months: (rule.monthsOfTheYear ?? []).map(\.intValue),
            yearDays: (rule.daysOfTheYear ?? []).map(\.intValue),
            weeksOfYear: (rule.weeksOfTheYear ?? []).map(\.intValue),
            setPositions: (rule.setPositions ?? []).map(\.intValue),
            firstWeekday: rule.firstDayOfTheWeek,
            endDate: rule.recurrenceEnd?.endDate,
            occurrenceCount: Int(rule.recurrenceEnd?.occurrenceCount ?? 0)
        )
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

    private static func colorComponents(from cgColor: CGColor) -> CalendarEventColor {
        let fallback = CalendarEventColor(red: 0.1, green: 0.48, blue: 1)
        guard let color = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB) else {
            return fallback
        }

        return CalendarEventColor(
            red: Double(color.redComponent),
            green: Double(color.greenComponent),
            blue: Double(color.blueComponent),
            opacity: Double(color.alphaComponent)
        )
    }
}

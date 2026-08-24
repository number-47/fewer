import AppKit
import EventKit
import FewerCore
import Foundation

/// 在专用 actor 边界上持有 `EKEventStore`，将 EventKit 查询与 EKEvent/EKReminder 到
/// `Sendable` 类型的映射全部隔离在主线程之外。
///
/// `EKEventStore` 本身线程安全，但单个 `EKEvent`/`EKReminder` 对象不是；因此在跨越
/// 边界返回前必须完成映射。提醒的异步查询通过 `withCheckedContinuation` 桥接为
/// `async`，并在 EventKit 内部回调队列上完成 EKReminder → Sendable 映射后再 resume。
///
/// 不在 actor 内取消提醒查询：`cancelFetchRequest` 不保证回调被调用，会导致 continuation
/// 永不 resume 而挂起。改由调用方（SystemCalendarService）通过 generation token 丢弃
/// 过期结果，配合 150ms 防抖减少并发查询。
actor EventKitWorker {
    private let eventStore = EKEventStore()

    // MARK: - 授权

    func requestFullAccessToEvents() async throws -> Bool {
        try await eventStore.requestFullAccessToEvents()
    }

    func requestFullAccessToReminders() async throws -> Bool {
        try await eventStore.requestFullAccessToReminders()
    }

    // MARK: - 事件查询

    /// 查询指定区间内的事件并映射为 `CalendarEventItem`（已隔离到 actor 内部）。
    func fetchEvents(in range: DateInterval) -> [CalendarEventItem] {
        let predicate = eventStore.predicateForEvents(
            withStart: range.start,
            end: range.end,
            calendars: nil
        )
        return eventStore.events(matching: predicate).map(Self.makeEventItem)
    }

    // MARK: - 提醒查询

    /// 查询所有提醒并在指定区间内展开重复项，映射为 `CalendarEventItem`。
    ///
    /// 回调在 EventKit 内部队列上执行，在 resume 前完成 EKReminder → Sendable 映射。
    /// 静态映射函数不访问 actor 状态，可在回调队列上安全调用。
    func fetchReminders(in visibleRange: DateInterval, calendar: Calendar) async -> [CalendarEventItem] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[CalendarEventItem], Never>) in
            let predicate = eventStore.predicateForReminders(in: nil)
            eventStore.fetchReminders(matching: predicate) { reminders in
                let items = (reminders ?? []).flatMap {
                    Self.makeReminderItems(from: $0, in: visibleRange, calendar: calendar)
                }
                continuation.resume(returning: items)
            }
        }
    }

    // MARK: - EK → CalendarEventItem 映射（静态，纯函数，不访问 actor 状态）

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

import Foundation

public enum ReminderRecurrenceFrequency: Sendable {
    case daily
    case weekly
    case monthly
    case yearly
}

public struct ReminderRecurrenceWeekday: Equatable, Sendable {
    public let weekday: Int
    public let ordinal: Int

    public init(weekday: Int, ordinal: Int = 0) {
        self.weekday = weekday
        self.ordinal = ordinal
    }
}

public struct ReminderRecurrenceRule: Sendable {
    public let frequency: ReminderRecurrenceFrequency
    public let interval: Int
    public let weekdays: [ReminderRecurrenceWeekday]
    public let monthDays: [Int]
    public let months: [Int]
    public let yearDays: [Int]
    public let weeksOfYear: [Int]
    public let setPositions: [Int]
    public let firstWeekday: Int
    public let endDate: Date?
    public let occurrenceCount: Int

    public init(
        frequency: ReminderRecurrenceFrequency,
        interval: Int = 1,
        weekdays: [ReminderRecurrenceWeekday] = [],
        monthDays: [Int] = [],
        months: [Int] = [],
        yearDays: [Int] = [],
        weeksOfYear: [Int] = [],
        setPositions: [Int] = [],
        firstWeekday: Int = 0,
        endDate: Date? = nil,
        occurrenceCount: Int = 0
    ) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.weekdays = weekdays
        self.monthDays = monthDays
        self.months = months
        self.yearDays = yearDays
        self.weeksOfYear = weeksOfYear
        self.setPositions = setPositions
        self.firstWeekday = firstWeekday
        self.endDate = endDate
        self.occurrenceCount = max(0, occurrenceCount)
    }
}

public enum ReminderRecurrence {
    public static func occurrenceDates(
        anchor: Date,
        rule: ReminderRecurrenceRule,
        in range: DateInterval,
        calendar: Calendar
    ) -> [Date] {
        guard range.duration > 0 else { return [] }

        if #available(macOS 15, *) {
            return foundationOccurrenceDates(
                anchor: anchor,
                rule: rule,
                in: range,
                calendar: calendar
            )
        }

        let anchorTime = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: anchor)
        var day = calendar.startOfDay(for: range.start)
        var occurrences: [Date] = []

        while day < range.end {
            guard let candidate = date(on: day, using: anchorTime, calendar: calendar) else {
                break
            }
            if candidate >= anchor,
               candidate >= range.start,
               candidate < range.end,
               isBeforeRecurrenceEnd(candidate, rule: rule),
               matches(candidate, anchor: anchor, rule: rule, calendar: calendar),
               isWithinOccurrenceCount(candidate, anchor: anchor, rule: rule, calendar: calendar) {
                occurrences.append(candidate)
            }

            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day), nextDay > day else {
                break
            }
            day = nextDay
        }

        return occurrences
    }

    @available(macOS 15, *)
    private static func foundationOccurrenceDates(
        anchor: Date,
        rule: ReminderRecurrenceRule,
        in range: DateInterval,
        calendar: Calendar
    ) -> [Date] {
        var recurrenceCalendar = calendar
        if (1...7).contains(rule.firstWeekday) {
            recurrenceCalendar.firstWeekday = rule.firstWeekday
        }

        let frequency: Calendar.RecurrenceRule.Frequency
        switch rule.frequency {
        case .daily:
            frequency = .daily
        case .weekly:
            frequency = .weekly
        case .monthly:
            frequency = .monthly
        case .yearly:
            frequency = .yearly
        }

        let recurrenceEnd: Calendar.RecurrenceRule.End
        if rule.occurrenceCount > 0 {
            recurrenceEnd = .afterOccurrences(rule.occurrenceCount)
        } else if let endDate = rule.endDate {
            recurrenceEnd = .afterDate(endDate)
        } else {
            recurrenceEnd = .never
        }

        let weekdays = rule.weekdays.compactMap { weekday -> Calendar.RecurrenceRule.Weekday? in
            guard let localeWeekday = localeWeekday(for: weekday.weekday) else { return nil }
            return weekday.ordinal == 0
                ? .every(localeWeekday)
                : .nth(weekday.ordinal, localeWeekday)
        }
        let recurrence = Calendar.RecurrenceRule(
            calendar: recurrenceCalendar,
            frequency: frequency,
            interval: rule.interval,
            end: recurrenceEnd,
            months: rule.months.map { Calendar.RecurrenceRule.Month($0) },
            daysOfTheYear: rule.yearDays,
            daysOfTheMonth: rule.monthDays,
            weeks: rule.weeksOfYear,
            weekdays: weekdays,
            setPositions: rule.setPositions
        )
        return Array(recurrence.recurrences(of: anchor, in: range.start..<range.end))
    }

    @available(macOS 15, *)
    private static func localeWeekday(for value: Int) -> Locale.Weekday? {
        switch value {
        case 1: return .sunday
        case 2: return .monday
        case 3: return .tuesday
        case 4: return .wednesday
        case 5: return .thursday
        case 6: return .friday
        case 7: return .saturday
        default: return nil
        }
    }

    private static func date(
        on day: Date,
        using time: DateComponents,
        calendar: Calendar
    ) -> Date? {
        calendar.date(bySettingHour: time.hour ?? 0,
                      minute: time.minute ?? 0,
                      second: time.second ?? 0,
                      of: day)
    }

    private static func isBeforeRecurrenceEnd(_ candidate: Date, rule: ReminderRecurrenceRule) -> Bool {
        guard let endDate = rule.endDate else { return true }
        return candidate <= endDate
    }

    private static func matches(
        _ candidate: Date,
        anchor: Date,
        rule: ReminderRecurrenceRule,
        calendar: Calendar
    ) -> Bool {
        switch rule.frequency {
        case .daily:
            let difference = calendar.dateComponents([.day], from: calendar.startOfDay(for: anchor), to: calendar.startOfDay(for: candidate)).day ?? -1
            return difference >= 0 && difference.isMultiple(of: rule.interval)

        case .weekly:
            guard let difference = weekDifference(from: anchor, to: candidate, rule: rule, calendar: calendar),
                  difference >= 0,
                  difference.isMultiple(of: rule.interval) else {
                return false
            }
            let allowedWeekdays = rule.weekdays.isEmpty
                ? [calendar.component(.weekday, from: anchor)]
                : rule.weekdays.map(\.weekday)
            return allowedWeekdays.contains(calendar.component(.weekday, from: candidate))

        case .monthly:
            let difference = monthDifference(from: anchor, to: candidate, calendar: calendar)
            guard difference >= 0, difference.isMultiple(of: rule.interval) else { return false }
            return matchesMonthDay(candidate, anchor: anchor, rule: rule, calendar: calendar)

        case .yearly:
            let anchorYear = calendar.component(.year, from: anchor)
            let candidateYear = calendar.component(.year, from: candidate)
            let difference = candidateYear - anchorYear
            guard difference >= 0, difference.isMultiple(of: rule.interval) else { return false }

            let candidateMonth = calendar.component(.month, from: candidate)
            let allowedMonths = rule.months.isEmpty
                ? [calendar.component(.month, from: anchor)]
                : rule.months
            guard allowedMonths.contains(candidateMonth) else { return false }
            return matchesMonthDay(candidate, anchor: anchor, rule: rule, calendar: calendar)
        }
    }

    private static func matchesMonthDay(
        _ candidate: Date,
        anchor: Date,
        rule: ReminderRecurrenceRule,
        calendar: Calendar
    ) -> Bool {
        let candidateDay = calendar.component(.day, from: candidate)
        if !rule.monthDays.isEmpty {
            guard let dayRange = calendar.range(of: .day, in: .month, for: candidate) else { return false }
            return rule.monthDays.contains { value in
                value > 0 ? candidateDay == value : candidateDay == dayRange.count + value + 1
            }
        }

        if !rule.weekdays.isEmpty {
            let candidateWeekday = calendar.component(.weekday, from: candidate)
            return rule.weekdays.contains { weekday in
                guard weekday.weekday == candidateWeekday else { return false }
                guard weekday.ordinal != 0 else { return true }
                let ordinals = weekdayOrdinals(for: candidate, calendar: calendar)
                return weekday.ordinal > 0
                    ? ordinals.positive == weekday.ordinal
                    : ordinals.negative == weekday.ordinal
            }
        }

        return candidateDay == calendar.component(.day, from: anchor)
    }

    private static func weekdayOrdinals(for date: Date, calendar: Calendar) -> (positive: Int, negative: Int) {
        let day = calendar.component(.day, from: date)
        guard let dayRange = calendar.range(of: .day, in: .month, for: date) else { return (0, 0) }
        let positiveOrdinal = ((day - 1) / 7) + 1
        let negativeOrdinal = -(((dayRange.count - day) / 7) + 1)
        return (positiveOrdinal, negativeOrdinal)
    }

    private static func weekDifference(
        from anchor: Date,
        to candidate: Date,
        rule: ReminderRecurrenceRule,
        calendar: Calendar
    ) -> Int? {
        var recurrenceCalendar = calendar
        recurrenceCalendar.firstWeekday = (1...7).contains(rule.firstWeekday) ? rule.firstWeekday : 2
        guard let anchorWeek = recurrenceCalendar.dateInterval(of: .weekOfYear, for: anchor)?.start,
              let candidateWeek = recurrenceCalendar.dateInterval(of: .weekOfYear, for: candidate)?.start else {
            return nil
        }
        return recurrenceCalendar.dateComponents([.weekOfYear], from: anchorWeek, to: candidateWeek).weekOfYear
    }

    private static func monthDifference(from anchor: Date, to candidate: Date, calendar: Calendar) -> Int {
        let anchorComponents = calendar.dateComponents([.year, .month], from: anchor)
        let candidateComponents = calendar.dateComponents([.year, .month], from: candidate)
        guard let anchorYear = anchorComponents.year,
              let anchorMonth = anchorComponents.month,
              let candidateYear = candidateComponents.year,
              let candidateMonth = candidateComponents.month else {
            return -1
        }
        return (candidateYear - anchorYear) * 12 + candidateMonth - anchorMonth
    }

    private static func isWithinOccurrenceCount(
        _ candidate: Date,
        anchor: Date,
        rule: ReminderRecurrenceRule,
        calendar: Calendar
    ) -> Bool {
        guard rule.occurrenceCount > 0,
              rule.weekdays.isEmpty,
              rule.monthDays.isEmpty,
              rule.months.isEmpty else {
            return true
        }

        let zeroBasedIndex: Int
        switch rule.frequency {
        case .daily:
            zeroBasedIndex = (calendar.dateComponents([.day], from: anchor, to: candidate).day ?? 0) / rule.interval
        case .weekly:
            zeroBasedIndex = (weekDifference(from: anchor, to: candidate, rule: rule, calendar: calendar) ?? 0) / rule.interval
        case .monthly:
            zeroBasedIndex = monthDifference(from: anchor, to: candidate, calendar: calendar) / rule.interval
        case .yearly:
            zeroBasedIndex = (calendar.component(.year, from: candidate) - calendar.component(.year, from: anchor)) / rule.interval
        }
        return zeroBasedIndex < rule.occurrenceCount
    }
}

import Foundation

public struct CalendarEventColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let opacity: Double

    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }
}

public enum CalendarItemKind: Equatable, Sendable {
    case event
    case reminder
}

public struct CalendarEventItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let isAllDay: Bool
    public let calendarTitle: String
    public let isSubscription: Bool
    public let color: CalendarEventColor
    public let kind: CalendarItemKind
    public let isCompleted: Bool

    public init(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        calendarTitle: String,
        isSubscription: Bool,
        color: CalendarEventColor,
        kind: CalendarItemKind = .event,
        isCompleted: Bool = false
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.calendarTitle = calendarTitle
        self.isSubscription = isSubscription
        self.color = color
        self.kind = kind
        self.isCompleted = isCompleted
    }

    public func overlaps(dayContaining date: Date, calendar: Calendar) -> Bool {
        guard let dayInterval = calendar.dateInterval(of: .day, for: date) else {
            return false
        }
        return startDate < dayInterval.end && endDate > dayInterval.start
    }

    public var isHoliday: Bool {
        kind == .event && isAllDay && isSubscription
    }

    public static func holidayTitle(in events: [CalendarEventItem]) -> String? {
        events.lazy.compactMap { event in
            guard event.isHoliday else { return nil }
            let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : title
        }.first
    }
}

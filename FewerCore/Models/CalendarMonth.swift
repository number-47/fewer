import Foundation

public struct CalendarDay: Identifiable, Equatable, Sendable {
    public let date: Date
    public let number: Int
    public let lunarText: String
    public let isInDisplayedMonth: Bool
    public let isToday: Bool

    public var id: Date { date }
}

public struct CalendarMonth: Equatable, Sendable {
    public let monthStart: Date
    public let days: [CalendarDay]
    public let weekdaySymbols: [String]

    public static func startDate(
        year: Int,
        month: Int,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date? {
        guard (1...12).contains(month) else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: 1))
    }

    /// 构建以指定日期所在月份为展示月份的固定 6 行（42 天）网格。
    public init(
        containing date: Date,
        today: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        let monthStart = calendar.dateInterval(of: .month, for: date)?.start ?? date
        self.init(anchoredAt: monthStart, today: today, calendar: calendar)
    }

    /// 以任意日期为锚点构建固定 6 行（42 天）网格，用于逐行（按周）滚动。
    /// 网格从锚点所在周的第一天开始；`monthStart` 为锚点所在月的开始，
    /// 网格中与锚点同月的日子 `isInDisplayedMonth` 为 true。
    public init(
        anchoredAt anchorDate: Date,
        today: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        weekdaySymbols = Self.orderedWeekdaySymbols(for: calendar)
        let anchorMonthStart = calendar.dateInterval(of: .month, for: anchorDate)?.start ?? anchorDate
        monthStart = anchorMonthStart

        let weekday = calendar.component(.weekday, from: anchorDate)
        let leadingDayCount = (weekday - calendar.firstWeekday + 7) % 7
        guard let gridStart = calendar.date(
            byAdding: .day,
            value: -leadingDayCount,
            to: anchorDate
        ) else {
            days = []
            return
        }

        days = (0..<42).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: gridStart) else {
                return nil
            }

            return CalendarDay(
                date: day,
                number: calendar.component(.day, from: day),
                lunarText: Self.lunarText(for: day, timeZone: calendar.timeZone),
                isInDisplayedMonth: calendar.isDate(day, equalTo: anchorMonthStart, toGranularity: .month),
                isToday: calendar.isDate(day, inSameDayAs: today)
            )
        }
    }

    private static func orderedWeekdaySymbols(for calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard symbols.count == 7 else { return symbols }

        let startIndex = max(0, min(6, calendar.firstWeekday - 1))
        return Array(symbols[startIndex...] + symbols[..<startIndex])
    }

    private static func lunarText(for date: Date, timeZone: TimeZone) -> String {
        var lunarCalendar = Calendar(identifier: .chinese)
        lunarCalendar.locale = Locale(identifier: "zh_CN")
        lunarCalendar.timeZone = timeZone

        let components = lunarCalendar.dateComponents([.month, .day, .isLeapMonth], from: date)
        guard let month = components.month, let day = components.day,
              monthNames.indices.contains(month - 1), dayNames.indices.contains(day - 1) else {
            return ""
        }

        if day == 1 {
            return (components.isLeapMonth == true ? "闰" : "") + monthNames[month - 1] + "月"
        }

        return dayNames[day - 1]
    }

    private static let monthNames = [
        "正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊",
    ]

    private static let dayNames = [
        "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
        "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
        "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十",
    ]
}

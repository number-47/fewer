import XCTest
@testable import FewerCore

final class CalendarMonthTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 1
        return calendar
    }

    func testBuildsFixedSixWeekGridStartingOnConfiguredWeekday() throws {
        let target = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 5)))
        let month = CalendarMonth(containing: target, today: target, calendar: calendar)

        XCTAssertEqual(month.days.count, 42)
        XCTAssertEqual(calendar.component(.weekday, from: try XCTUnwrap(month.days.first?.date)), 1)
        XCTAssertEqual(month.days.filter(\.isInDisplayedMonth).count, 31)
        XCTAssertEqual(month.days.filter(\.isToday).map(\.number), [5])
    }

    func testWeekdaySymbolsFollowCalendarFirstWeekday() throws {
        var mondayFirstCalendar = calendar
        mondayFirstCalendar.firstWeekday = 2
        let target = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 5)))

        let month = CalendarMonth(containing: target, calendar: mondayFirstCalendar)

        XCTAssertEqual(month.weekdaySymbols.first, mondayFirstCalendar.veryShortStandaloneWeekdaySymbols[1])
        XCTAssertEqual(month.weekdaySymbols.count, 7)
    }

    func testWeekdaySymbolsFollowCalendarLocale() throws {
        let target = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 5)))
        var chineseCalendar = calendar
        chineseCalendar.locale = Locale(identifier: "zh_Hans_CN")
        var englishCalendar = calendar
        englishCalendar.locale = Locale(identifier: "en_US")

        let chineseMonth = CalendarMonth(containing: target, calendar: chineseCalendar)
        let englishMonth = CalendarMonth(containing: target, calendar: englishCalendar)

        XCTAssertEqual(chineseMonth.weekdaySymbols, orderedSymbols(for: chineseCalendar))
        XCTAssertEqual(englishMonth.weekdaySymbols, orderedSymbols(for: englishCalendar))
        XCTAssertNotEqual(chineseMonth.weekdaySymbols, englishMonth.weekdaySymbols)
    }

    func testEveryVisibleDayHasLunarText() throws {
        let target = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 5)))
        let month = CalendarMonth(containing: target, calendar: calendar)

        XCTAssertTrue(month.days.allSatisfy { !$0.lunarText.isEmpty })
    }

    func testStartDateBuildsFirstDayForSelectedYearAndMonth() throws {
        let date = try XCTUnwrap(CalendarMonth.startDate(year: 2042, month: 11, calendar: calendar))
        let components = calendar.dateComponents([.year, .month, .day], from: date)

        XCTAssertEqual(components.year, 2042)
        XCTAssertEqual(components.month, 11)
        XCTAssertEqual(components.day, 1)
    }

    func testStartDateRejectsInvalidMonth() {
        XCTAssertNil(CalendarMonth.startDate(year: 2026, month: 0, calendar: calendar))
        XCTAssertNil(CalendarMonth.startDate(year: 2026, month: 13, calendar: calendar))
    }

    func testAnchoredGridStartsOnAnchorWeekAndHighlightsAnchorMonth() throws {
        let anchor = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 19)))
        let month = CalendarMonth(anchoredAt: anchor, today: anchor, calendar: calendar)

        XCTAssertEqual(month.days.count, 42)
        // 网格从锚点所在周的第一天（周日）开始：2026-08-16 是周日。
        let firstDay = try XCTUnwrap(month.days.first?.date)
        XCTAssertEqual(calendar.component(.weekday, from: firstDay), 1)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: firstDay).day, 16)
        // 标题月份 = 锚点所在月。
        XCTAssertEqual(calendar.dateComponents([.year, .month], from: month.monthStart).month, 8)
        // 网格中仅锚点所在月（8 月）的日子标记为当月：8-16 ~ 8-31 共 16 天。
        let displayedDays = month.days.filter(\.isInDisplayedMonth)
        XCTAssertEqual(displayedDays.count, 16)
        XCTAssertTrue(displayedDays.allSatisfy {
            calendar.isDate($0.date, equalTo: anchor, toGranularity: .month)
        })
        XCTAssertTrue(month.days.contains {
            calendar.isDate($0.date, inSameDayAs: anchor) && $0.isToday
        })
    }

    func testAnchoredGridAdvancesOneWeekPerAnchorStep() throws {
        let firstAnchor = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 19)))
        // 滚动一周后锚点仍在 8 月，标题月份保持不变。
        let nextAnchor = try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: firstAnchor))
        let first = CalendarMonth(anchoredAt: firstAnchor, today: firstAnchor, calendar: calendar)
        let next = CalendarMonth(anchoredAt: nextAnchor, today: nextAnchor, calendar: calendar)

        // 锚点前进一周后，网格起点也整体前进一周（逐行滚动效果）。
        let firstGridStart = try XCTUnwrap(first.days.first?.date)
        let nextGridStart = try XCTUnwrap(next.days.first?.date)
        let dayDiff = calendar.dateComponents([.day], from: firstGridStart, to: nextGridStart).day
        XCTAssertEqual(dayDiff, 7)
        XCTAssertEqual(calendar.dateComponents([.year, .month], from: next.monthStart).month, 8)
    }

    func testAnchoredGridFollowsAnchorAcrossMonthBoundary() throws {
        let firstAnchor = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 19)))
        // 滚动两周后锚点进入 9 月，标题月份跟随迁移。
        let nextAnchor = try XCTUnwrap(calendar.date(byAdding: .day, value: 14, to: firstAnchor))
        let first = CalendarMonth(anchoredAt: firstAnchor, today: firstAnchor, calendar: calendar)
        let next = CalendarMonth(anchoredAt: nextAnchor, today: nextAnchor, calendar: calendar)

        let firstGridStart = try XCTUnwrap(first.days.first?.date)
        let nextGridStart = try XCTUnwrap(next.days.first?.date)
        let dayDiff = calendar.dateComponents([.day], from: firstGridStart, to: nextGridStart).day
        XCTAssertEqual(dayDiff, 14)
        XCTAssertEqual(calendar.dateComponents([.year, .month], from: next.monthStart).month, 9)
        // 9 月的日子在网格中标记为当月。
        XCTAssertTrue(next.days.filter(\.isInDisplayedMonth).allSatisfy {
            calendar.isDate($0.date, equalTo: nextAnchor, toGranularity: .month)
        })
    }

    func testTodayHighlightUsesProvidedTodayNotSystemNow() throws {
        let anchor = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 15)))
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 20)))

        let month = CalendarMonth(anchoredAt: anchor, today: today, calendar: calendar)

        let todayDays = month.days.filter(\.isToday)
        XCTAssertEqual(todayDays.count, 1)
        XCTAssertEqual(calendar.component(.day, from: todayDays[0].date), 20)
    }

    func testDifferentTimeZonesProduceDifferentMonthStarts() throws {
        let anchor = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 15)))

        var shanghaiCalendar = calendar
        shanghaiCalendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!

        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!

        let shanghaiMonth = CalendarMonth(anchoredAt: anchor, today: anchor, calendar: shanghaiCalendar)
        let utcMonth = CalendarMonth(anchoredAt: anchor, today: anchor, calendar: utcCalendar)

        let shanghaiStart = shanghaiMonth.monthStart
        let utcStart = utcMonth.monthStart

        XCTAssertNotEqual(shanghaiStart, utcStart)

        let hourDiff = shanghaiCalendar.dateComponents([.hour], from: utcStart, to: shanghaiStart).hour ?? 0
        XCTAssertEqual(abs(hourDiff), 8)
    }

    func testAnchoredGridCrossesYearBoundary() throws {
        let anchor = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 12, day: 25)))
        let nextAnchor = try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: anchor))

        let month = CalendarMonth(anchoredAt: nextAnchor, today: nextAnchor, calendar: calendar)

        XCTAssertEqual(calendar.component(.year, from: month.monthStart), 2027)
        XCTAssertEqual(calendar.component(.month, from: month.monthStart), 1)
        XCTAssertTrue(month.days.contains {
            calendar.component(.year, from: $0.date) == 2026 && $0.isInDisplayedMonth == false
        })
    }

    func testEnglishLocaleProducesEmptyLunarText() throws {
        let anchor = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 15)))

        var englishCalendar = calendar
        englishCalendar.locale = Locale(identifier: "en_US")

        let month = CalendarMonth(anchoredAt: anchor, today: anchor, calendar: englishCalendar)

        XCTAssertTrue(month.days.allSatisfy { !$0.lunarText.isEmpty })
    }

    func testFirstWeekdayShiftsGridStartDay() throws {
        let anchor = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 19)))

        var sundayFirst = calendar
        sundayFirst.firstWeekday = 1

        var mondayFirst = calendar
        mondayFirst.firstWeekday = 2

        let sundayMonth = CalendarMonth(anchoredAt: anchor, today: anchor, calendar: sundayFirst)
        let mondayMonth = CalendarMonth(anchoredAt: anchor, today: anchor, calendar: mondayFirst)

        let sundayStart = try XCTUnwrap(sundayMonth.days.first?.date)
        let mondayStart = try XCTUnwrap(mondayMonth.days.first?.date)

        XCTAssertEqual(sundayFirst.component(.weekday, from: sundayStart), 1)
        XCTAssertEqual(mondayFirst.component(.weekday, from: mondayStart), 2)
    }

    private func orderedSymbols(for calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let startIndex = calendar.firstWeekday - 1
        return Array(symbols[startIndex...] + symbols[..<startIndex])
    }
}

import XCTest
@testable import FewerCore

final class ReminderRecurrenceTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 2
        return calendar
    }

    func testMonthlyReminderExpandsOldMasterOntoVisibleTwentyFirst() throws {
        let anchor = try date(year: 2025, month: 11, day: 21)
        let range = DateInterval(
            start: try date(year: 2026, month: 7, day: 26),
            end: try date(year: 2026, month: 9, day: 7)
        )
        let rule = ReminderRecurrenceRule(frequency: .monthly)

        let occurrences = ReminderRecurrence.occurrenceDates(
            anchor: anchor,
            rule: rule,
            in: range,
            calendar: calendar
        )

        XCTAssertEqual(occurrences, [try date(year: 2026, month: 8, day: 21)])
    }

    func testWeeklyReminderSupportsMultipleWeekdays() throws {
        let anchor = try date(year: 2026, month: 8, day: 3, hour: 9)
        let range = DateInterval(
            start: try date(year: 2026, month: 8, day: 2),
            end: try date(year: 2026, month: 8, day: 11)
        )
        let rule = ReminderRecurrenceRule(
            frequency: .weekly,
            weekdays: [
                ReminderRecurrenceWeekday(weekday: 2),
                ReminderRecurrenceWeekday(weekday: 4),
            ]
        )

        let occurrences = ReminderRecurrence.occurrenceDates(
            anchor: anchor,
            rule: rule,
            in: range,
            calendar: calendar
        )

        XCTAssertEqual(occurrences, [
            try date(year: 2026, month: 8, day: 3, hour: 9),
            try date(year: 2026, month: 8, day: 5, hour: 9),
            try date(year: 2026, month: 8, day: 10, hour: 9),
        ])
    }

    func testYearlyLeapDayOnlyAppearsInLeapYear() throws {
        let anchor = try date(year: 2024, month: 2, day: 29)
        let rule = ReminderRecurrenceRule(frequency: .yearly)
        let nonLeapRange = DateInterval(
            start: try date(year: 2026, month: 2, day: 1),
            end: try date(year: 2026, month: 3, day: 1)
        )
        let leapRange = DateInterval(
            start: try date(year: 2028, month: 2, day: 1),
            end: try date(year: 2028, month: 3, day: 1)
        )

        XCTAssertTrue(ReminderRecurrence.occurrenceDates(
            anchor: anchor,
            rule: rule,
            in: nonLeapRange,
            calendar: calendar
        ).isEmpty)
        XCTAssertEqual(ReminderRecurrence.occurrenceDates(
            anchor: anchor,
            rule: rule,
            in: leapRange,
            calendar: calendar
        ), [try date(year: 2028, month: 2, day: 29)])
    }

    func testOccurrenceCountStopsSimpleMonthlyReminder() throws {
        let anchor = try date(year: 2026, month: 1, day: 21)
        let range = DateInterval(
            start: try date(year: 2026, month: 1, day: 1),
            end: try date(year: 2026, month: 6, day: 1)
        )
        let rule = ReminderRecurrenceRule(frequency: .monthly, occurrenceCount: 3)

        let occurrences = ReminderRecurrence.occurrenceDates(
            anchor: anchor,
            rule: rule,
            in: range,
            calendar: calendar
        )

        XCTAssertEqual(occurrences, [
            try date(year: 2026, month: 1, day: 21),
            try date(year: 2026, month: 2, day: 21),
            try date(year: 2026, month: 3, day: 21),
        ])
    }

    private func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour
        )))
    }
}

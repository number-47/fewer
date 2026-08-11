import XCTest
@testable import FewerCore

final class CalendarEventItemTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    func testEventOverlapsEachCoveredDay() throws {
        let start = try date(year: 2026, month: 8, day: 5, hour: 22)
        let end = try date(year: 2026, month: 8, day: 6, hour: 2)
        let event = makeEvent(start: start, end: end)

        XCTAssertTrue(event.overlaps(dayContaining: start, calendar: calendar))
        XCTAssertTrue(event.overlaps(
            dayContaining: try date(year: 2026, month: 8, day: 6),
            calendar: calendar
        ))
        XCTAssertFalse(event.overlaps(
            dayContaining: try date(year: 2026, month: 8, day: 7),
            calendar: calendar
        ))
    }

    func testEventEndingAtDayStartDoesNotOverlapThatDay() throws {
        let start = try date(year: 2026, month: 8, day: 5)
        let end = try date(year: 2026, month: 8, day: 6)
        let event = makeEvent(start: start, end: end)

        XCTAssertFalse(event.overlaps(dayContaining: end, calendar: calendar))
    }

    func testItemKindDefaultsToEventAndSupportsReminder() throws {
        let start = try date(year: 2026, month: 8, day: 5, hour: 9)
        let event = makeEvent(start: start, end: start.addingTimeInterval(60))
        let reminder = CalendarEventItem(
            id: "reminder",
            title: "Plan",
            startDate: start,
            endDate: start.addingTimeInterval(60),
            isAllDay: false,
            calendarTitle: "Reminders",
            isSubscription: false,
            color: CalendarEventColor(red: 1, green: 0.5, blue: 0),
            kind: .reminder
        )

        XCTAssertEqual(event.kind, .event)
        XCTAssertEqual(reminder.kind, .reminder)
        XCTAssertTrue(reminder.overlaps(dayContaining: start, calendar: calendar))
    }

    func testHolidayTitleUsesAllDaySubscriptionEvent() throws {
        let start = try date(year: 2026, month: 10, day: 1)
        let holiday = CalendarEventItem(
            id: "holiday",
            title: " 国庆节 ",
            startDate: start,
            endDate: try date(year: 2026, month: 10, day: 2),
            isAllDay: true,
            calendarTitle: "中国大陆节假日",
            isSubscription: true,
            color: CalendarEventColor(red: 1, green: 0, blue: 0)
        )

        XCTAssertTrue(holiday.isHoliday)
        XCTAssertEqual(CalendarEventItem.holidayTitle(in: [holiday]), "国庆节")
    }

    func testHolidayTitleIgnoresReminderAndRegularEvent() throws {
        let start = try date(year: 2026, month: 10, day: 1)
        let regularEvent = makeEvent(start: start, end: start.addingTimeInterval(60))
        let reminder = CalendarEventItem(
            id: "reminder",
            title: "国庆安排",
            startDate: start,
            endDate: start.addingTimeInterval(60),
            isAllDay: true,
            calendarTitle: "计划",
            isSubscription: true,
            color: CalendarEventColor(red: 1, green: 0.5, blue: 0),
            kind: .reminder
        )

        XCTAssertNil(CalendarEventItem.holidayTitle(in: [regularEvent, reminder]))
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

    private func makeEvent(start: Date, end: Date) -> CalendarEventItem {
        CalendarEventItem(
            id: "event",
            title: "Test",
            startDate: start,
            endDate: end,
            isAllDay: false,
            calendarTitle: "Calendar",
            isSubscription: false,
            color: CalendarEventColor(red: 0, green: 0.5, blue: 1)
        )
    }
}

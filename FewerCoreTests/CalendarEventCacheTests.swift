import XCTest
@testable import FewerCore

final class CalendarEventCacheTests: XCTestCase {
    private func makeRange(startDay: Int) -> DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 8, day: startDay))!
        let end = calendar.date(byAdding: .day, value: 42, to: start)!
        return DateInterval(start: start, end: end)
    }

    private func makeEvents(prefix: String) -> [CalendarEventItem] {
        [
            CalendarEventItem(
                id: "\(prefix)-1",
                title: "\(prefix) Event",
                startDate: Date(timeIntervalSince1970: 1_800_000_000),
                endDate: Date(timeIntervalSince1970: 1_800_3600),
                isAllDay: false,
                calendarTitle: "Test",
                isSubscription: false,
                color: CalendarEventColor(red: 0.1, green: 0.2, blue: 0.3)
            ),
        ]
    }

    func testInsertAndHitReturnsSameEvents() {
        var cache = CalendarEventCache(maxEntries: 4)
        let range = makeRange(startDay: 1)
        let events = makeEvents(prefix: "A")

        cache.insert(events, for: range)

        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.events(for: range), events)
    }

    func testMissReturnsNil() {
        let cache = CalendarEventCache(maxEntries: 4)

        XCTAssertNil(cache.events(for: makeRange(startDay: 1)))
    }

    func testReinsertSameRangeUpdatesAndDoesNotGrowCount() {
        var cache = CalendarEventCache(maxEntries: 4)
        let range = makeRange(startDay: 1)

        cache.insert(makeEvents(prefix: "A"), for: range)
        cache.insert(makeEvents(prefix: "B"), for: range)

        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.events(for: range)?.first?.title, "B Event")
    }

    func testEvictsOldestInsertionWhenExceedingMaxEntries() {
        var cache = CalendarEventCache(maxEntries: 2)
        let range1 = makeRange(startDay: 1)
        let range2 = makeRange(startDay: 43)
        let range3 = makeRange(startDay: 86)

        cache.insert(makeEvents(prefix: "1"), for: range1)
        cache.insert(makeEvents(prefix: "2"), for: range2)
        XCTAssertNotNil(cache.events(for: range1))
        XCTAssertNotNil(cache.events(for: range2))

        cache.insert(makeEvents(prefix: "3"), for: range3)
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.events(for: range1))
        XCTAssertNotNil(cache.events(for: range3))
    }

    func testReadDoesNotPromoteEntry() {
        var cache = CalendarEventCache(maxEntries: 2)
        let range1 = makeRange(startDay: 1)
        let range2 = makeRange(startDay: 43)
        let range3 = makeRange(startDay: 86)

        cache.insert(makeEvents(prefix: "1"), for: range1)
        cache.insert(makeEvents(prefix: "2"), for: range2)

        _ = cache.events(for: range1)

        cache.insert(makeEvents(prefix: "3"), for: range3)

        XCTAssertNil(cache.events(for: range1))
        XCTAssertNotNil(cache.events(for: range2))
        XCTAssertEqual(cache.count, 2)
    }

    func testClearRemovesAllEntries() {
        var cache = CalendarEventCache(maxEntries: 4)
        let range = makeRange(startDay: 1)
        cache.insert(makeEvents(prefix: "A"), for: range)

        cache.clear()

        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.events(for: range))
    }

    func testMaxEntriesClampedToOne() {
        var cache = CalendarEventCache(maxEntries: 0)
        let range1 = makeRange(startDay: 1)
        let range2 = makeRange(startDay: 43)

        cache.insert(makeEvents(prefix: "1"), for: range1)
        cache.insert(makeEvents(prefix: "2"), for: range2)

        XCTAssertEqual(cache.count, 1)
        XCTAssertNil(cache.events(for: range1))
        XCTAssertNotNil(cache.events(for: range2))
    }
}

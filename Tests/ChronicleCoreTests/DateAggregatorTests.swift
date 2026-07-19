import XCTest
@testable import ChronicleCore

final class DateAggregatorTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    private lazy var aggregator = DateAggregator(calendar: calendar)

    private func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    private func event(_ title: String,
                       _ start: String,
                       _ end: String,
                       calendar name: String = "Work",
                       color: String? = nil,
                       allDay: Bool = false) -> EventInput {
        EventInput(calendar: TitleParser.normalize(name),
                   title: TitleParser.parse(title)!,
                   start: date(start),
                   end: date(end),
                   isAllDay: allDay,
                   calendarColor: color)
    }

    private func window() -> ExtractionWindow {
        ExtractionWindow(start: date("2026-07-01 00:00"), end: date("2026-08-01 00:00"))
    }

    func testSimpleEventDurationAndCount() {
        let rows = aggregator.aggregate([
            event("Code Reviews", "2026-07-07 09:00", "2026-07-07 13:30")
        ], window: window())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].date, "2026-07-07")
        XCTAssertEqual(rows[0].durationSeconds, Int(4.5 * 3600))
        XCTAssertEqual(rows[0].occurrenceCount, 1)
    }

    func testAllDayEventsSkipped() {
        let rows = aggregator.aggregate([
            event("Code Reviews", "2026-07-07 00:00", "2026-07-08 00:00", allDay: true)
        ], window: window())
        XCTAssertTrue(rows.isEmpty)
    }

    func testMidnightCrossingSplitsDurationButCountsOnce() {
        // 22:00 -> 02:00 next day = 2h + 2h, occurrence only on start day.
        let rows = aggregator.aggregate([
            event("Deploy", "2026-07-07 22:00", "2026-07-08 02:00")
        ], window: window())
        let byDate = Dictionary(uniqueKeysWithValues: rows.map { ($0.date, $0) })
        XCTAssertEqual(byDate["2026-07-07"]?.durationSeconds, 2 * 3600)
        XCTAssertEqual(byDate["2026-07-08"]?.durationSeconds, 2 * 3600)
        XCTAssertEqual(byDate["2026-07-07"]?.occurrenceCount, 1)
        XCTAssertEqual(byDate["2026-07-08"]?.occurrenceCount, 0)
    }

    func testClipToWindow() {
        // Event starts before the window; only the in-window portion counts.
        let w = ExtractionWindow(start: date("2026-07-07 00:00"), end: date("2026-08-01 00:00"))
        let rows = aggregator.aggregate([
            event("Deploy", "2026-07-06 23:00", "2026-07-07 01:00")
        ], window: w)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].date, "2026-07-07")
        XCTAssertEqual(rows[0].durationSeconds, 3600)
        // Occurrence lands on the clipped start day (first day in window).
        XCTAssertEqual(rows[0].occurrenceCount, 1)
    }

    func testSameHierarchySameDayAccumulates() {
        let rows = aggregator.aggregate([
            event("Code Reviews", "2026-07-07 09:00", "2026-07-07 10:00"),
            event("Code Reviews", "2026-07-07 14:00", "2026-07-07 16:00")
        ], window: window())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].durationSeconds, 3 * 3600)
        XCTAssertEqual(rows[0].occurrenceCount, 2)
    }

    func testCalendarColorCarriesThroughAndSplits() {
        // Color propagates to the row, including across a midnight split.
        let rows = aggregator.aggregate([
            event("Deploy", "2026-07-07 22:00", "2026-07-08 02:00", color: "#FF9500")
        ], window: window())
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.calendarColor == "#FF9500" })
    }
}

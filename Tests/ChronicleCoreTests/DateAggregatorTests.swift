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
                       allDay: Bool = false,
                       subtractive: Bool = false) -> EventInput {
        EventInput(calendar: TitleParser.normalize(name),
                   title: TitleParser.parse(title)!,
                   start: date(start),
                   end: date(end),
                   isAllDay: allDay,
                   calendarColor: color,
                   isSubtractive: subtractive)
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

    // MARK: - Subtractive calendars

    private func row(_ rows: [DailyRow], cal: String, task: String, date: String) -> DailyRow? {
        rows.first { $0.calendarKey == cal && $0.taskKey == task && $0.date == date }
    }

    func testSubtractiveTrailingOverlap() {
        // A: Swim 12–5pm, B(subtractive): Instagram 2–5pm.
        // Swim = 2h [12–2], Instagram = 3h.
        let rows = aggregator.aggregate([
            event("Swim", "2026-07-07 12:00", "2026-07-07 17:00", calendar: "Personal"),
            event("Instagram", "2026-07-07 14:00", "2026-07-07 17:00",
                  calendar: "Instagram", subtractive: true)
        ], window: window())
        XCTAssertEqual(row(rows, cal: "personal", task: "swim", date: "2026-07-07")?.durationSeconds,
                       2 * 3600)
        XCTAssertEqual(row(rows, cal: "instagram", task: "instagram", date: "2026-07-07")?.durationSeconds,
                       3 * 3600)
    }

    func testSubtractivePartialOverlapCountsSubtractiveInFull() {
        // A: Swim 12–5pm, B(subtractive): Instagram 4–7pm.
        // Swim = 4h [12–4], Instagram = 3h (full, despite 2h being outside Swim).
        let rows = aggregator.aggregate([
            event("Swim", "2026-07-07 12:00", "2026-07-07 17:00", calendar: "Personal"),
            event("Instagram", "2026-07-07 16:00", "2026-07-07 19:00",
                  calendar: "Instagram", subtractive: true)
        ], window: window())
        XCTAssertEqual(row(rows, cal: "personal", task: "swim", date: "2026-07-07")?.durationSeconds,
                       4 * 3600)
        XCTAssertEqual(row(rows, cal: "instagram", task: "instagram", date: "2026-07-07")?.durationSeconds,
                       3 * 3600)
    }

    func testSubtractiveMiddleOverlapSplitsEvent() {
        // Subtractive interval carved out of the middle leaves two pieces.
        // Swim 12–6, Instagram 2–3 → Swim = 5h, occurrence counted once.
        let rows = aggregator.aggregate([
            event("Swim", "2026-07-07 12:00", "2026-07-07 18:00", calendar: "Personal"),
            event("Instagram", "2026-07-07 14:00", "2026-07-07 15:00",
                  calendar: "Instagram", subtractive: true)
        ], window: window())
        let swim = row(rows, cal: "personal", task: "swim", date: "2026-07-07")
        XCTAssertEqual(swim?.durationSeconds, 5 * 3600)
        XCTAssertEqual(swim?.occurrenceCount, 1)
    }

    func testSubtractiveNoOverlapLeavesEventIntact() {
        // Subtractive event on a disjoint interval doesn't touch Swim.
        let rows = aggregator.aggregate([
            event("Swim", "2026-07-07 12:00", "2026-07-07 17:00", calendar: "Personal"),
            event("Instagram", "2026-07-07 19:00", "2026-07-07 20:00",
                  calendar: "Instagram", subtractive: true)
        ], window: window())
        XCTAssertEqual(row(rows, cal: "personal", task: "swim", date: "2026-07-07")?.durationSeconds,
                       5 * 3600)
        XCTAssertEqual(row(rows, cal: "instagram", task: "instagram", date: "2026-07-07")?.durationSeconds,
                       3600)
    }

    func testMultipleSubtractiveIntervalsFromDifferentCalendars() {
        // Two subtractive events (even from different calendars) both carve out.
        // Swim 12–6; cuts 1–2 and 4–5 → remaining 12–1,2–4,5–6 = 4h.
        let rows = aggregator.aggregate([
            event("Swim", "2026-07-07 12:00", "2026-07-07 18:00", calendar: "Personal"),
            event("Instagram", "2026-07-07 13:00", "2026-07-07 14:00",
                  calendar: "Instagram", subtractive: true),
            event("News", "2026-07-07 16:00", "2026-07-07 17:00",
                  calendar: "Distraction", subtractive: true)
        ], window: window())
        XCTAssertEqual(row(rows, cal: "personal", task: "swim", date: "2026-07-07")?.durationSeconds,
                       4 * 3600)
    }

    func testFullySubtractedEventStillCountsOccurrence() {
        // Instagram fully covers Swim → 0 duration, but the occurrence remains.
        let rows = aggregator.aggregate([
            event("Swim", "2026-07-07 14:00", "2026-07-07 15:00", calendar: "Personal"),
            event("Instagram", "2026-07-07 12:00", "2026-07-07 18:00",
                  calendar: "Instagram", subtractive: true)
        ], window: window())
        let swim = row(rows, cal: "personal", task: "swim", date: "2026-07-07")
        XCTAssertEqual(swim?.durationSeconds, 0)
        XCTAssertEqual(swim?.occurrenceCount, 1)
    }

    func testSubtractiveEventCrossingMidnightSubtractsAcrossDays() {
        // Swim 22:00–02:00 (2h+2h). Instagram 23:00–01:00 subtractive.
        // Remaining: 22–23 (1h day7) and 01–02 (1h day8).
        let rows = aggregator.aggregate([
            event("Swim", "2026-07-07 22:00", "2026-07-08 02:00", calendar: "Personal"),
            event("Instagram", "2026-07-07 23:00", "2026-07-08 01:00",
                  calendar: "Instagram", subtractive: true)
        ], window: window())
        XCTAssertEqual(row(rows, cal: "personal", task: "swim", date: "2026-07-07")?.durationSeconds,
                       3600)
        XCTAssertEqual(row(rows, cal: "personal", task: "swim", date: "2026-07-08")?.durationSeconds,
                       3600)
        // Occurrence stays on the start day only.
        XCTAssertEqual(row(rows, cal: "personal", task: "swim", date: "2026-07-07")?.occurrenceCount, 1)
        XCTAssertEqual(row(rows, cal: "personal", task: "swim", date: "2026-07-08")?.occurrenceCount, 0)
    }

    func testSubtractiveCalendarsDoNotSubtractFromEachOther() {
        // Two overlapping subtractive events each count in full.
        let rows = aggregator.aggregate([
            event("Instagram", "2026-07-07 12:00", "2026-07-07 15:00",
                  calendar: "Instagram", subtractive: true),
            event("News", "2026-07-07 14:00", "2026-07-07 16:00",
                  calendar: "Distraction", subtractive: true)
        ], window: window())
        XCTAssertEqual(row(rows, cal: "instagram", task: "instagram", date: "2026-07-07")?.durationSeconds,
                       3 * 3600)
        XCTAssertEqual(row(rows, cal: "distraction", task: "news", date: "2026-07-07")?.durationSeconds,
                       2 * 3600)
    }
}

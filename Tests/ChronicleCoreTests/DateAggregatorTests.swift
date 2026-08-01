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
                       rank: Int = Int.max) -> EventInput {
        EventInput(calendar: TitleParser.normalize(name),
                   title: TitleParser.parse(title)!,
                   start: date(start),
                   end: date(end),
                   isAllDay: allDay,
                   calendarColor: color,
                   calendarRank: rank)
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

    // MARK: - Calendar priority

    private func row(_ rows: [DailyRow], cal: String, task: String, date: String) -> DailyRow? {
        rows.first { $0.calendarKey == cal && $0.taskKey == task && $0.date == date }
    }

    func testHigherPriorityTrailingOverlap() {
        // Instagram (rank 0) outranks Personal (rank 1).
        // Swim 12–5pm, Instagram 2–5pm → Swim = 2h [12–2], Instagram = 3h.
        let rows = aggregator.aggregate([
            event("Swim", "2026-07-07 12:00", "2026-07-07 17:00", calendar: "Personal", rank: 1),
            event("Instagram", "2026-07-07 14:00", "2026-07-07 17:00",
                  calendar: "Instagram", rank: 0)
        ], window: window())
        XCTAssertEqual(row(rows, cal: "personal", task: "swim", date: "2026-07-07")?.durationSeconds,
                       2 * 3600)
        XCTAssertEqual(row(rows, cal: "instagram", task: "instagram", date: "2026-07-07")?.durationSeconds,
                       3 * 3600)
    }

    func testPartialOverlapCountsHigherPriorityInFull() {
        // Swim 12–5pm, Instagram 4–7pm.
        // Swim = 4h [12–4], Instagram = 3h (full, despite 2h being outside Swim).
        let rows = aggregator.aggregate([
            event("Swim", "2026-07-07 12:00", "2026-07-07 17:00", calendar: "Personal", rank: 1),
            event("Instagram", "2026-07-07 16:00", "2026-07-07 19:00",
                  calendar: "Instagram", rank: 0)
        ], window: window())
        XCTAssertEqual(row(rows, cal: "personal", task: "swim", date: "2026-07-07")?.durationSeconds,
                       4 * 3600)
        XCTAssertEqual(row(rows, cal: "instagram", task: "instagram", date: "2026-07-07")?.durationSeconds,
                       3 * 3600)
    }

    func testMiddleOverlapSplitsEvent() {
        // A higher-priority interval carved out of the middle leaves two pieces.
        // Swim 12–6, Instagram 2–3 → Swim = 5h, occurrence counted once.
        let rows = aggregator.aggregate([
            event("Swim", "2026-07-07 12:00", "2026-07-07 18:00", calendar: "Personal", rank: 1),
            event("Instagram", "2026-07-07 14:00", "2026-07-07 15:00",
                  calendar: "Instagram", rank: 0)
        ], window: window())
        let swim = row(rows, cal: "personal", task: "swim", date: "2026-07-07")
        XCTAssertEqual(swim?.durationSeconds, 5 * 3600)
        XCTAssertEqual(swim?.occurrenceCount, 1)
    }

    func testNoOverlapLeavesEventIntact() {
        // A higher-priority event on a disjoint interval doesn't touch Swim.
        let rows = aggregator.aggregate([
            event("Swim", "2026-07-07 12:00", "2026-07-07 17:00", calendar: "Personal", rank: 1),
            event("Instagram", "2026-07-07 19:00", "2026-07-07 20:00",
                  calendar: "Instagram", rank: 0)
        ], window: window())
        XCTAssertEqual(row(rows, cal: "personal", task: "swim", date: "2026-07-07")?.durationSeconds,
                       5 * 3600)
        XCTAssertEqual(row(rows, cal: "instagram", task: "instagram", date: "2026-07-07")?.durationSeconds,
                       3600)
    }

    func testCutsFromEveryHigherPriorityCalendarAccumulate() {
        // Swim (rank 2) sits below both Instagram (0) and Distraction (1);
        // cuts 1–2 and 4–5 → remaining 12–1, 2–4, 5–6 = 4h.
        let rows = aggregator.aggregate([
            event("Swim", "2026-07-07 12:00", "2026-07-07 18:00", calendar: "Personal", rank: 2),
            event("Instagram", "2026-07-07 13:00", "2026-07-07 14:00",
                  calendar: "Instagram", rank: 0),
            event("News", "2026-07-07 16:00", "2026-07-07 17:00",
                  calendar: "Distraction", rank: 1)
        ], window: window())
        XCTAssertEqual(row(rows, cal: "personal", task: "swim", date: "2026-07-07")?.durationSeconds,
                       4 * 3600)
    }

    func testPriorityCascadesDownTheOrder() {
        // A > B > C, all overlapping 12–6:
        // A keeps 12–2 (2h), B loses A's slice and keeps 2–4 (2h), C loses both.
        let rows = aggregator.aggregate([
            event("Alpha", "2026-07-07 12:00", "2026-07-07 14:00", calendar: "A", rank: 0),
            event("Bravo", "2026-07-07 12:00", "2026-07-07 16:00", calendar: "B", rank: 1),
            event("Charlie", "2026-07-07 12:00", "2026-07-07 18:00", calendar: "C", rank: 2)
        ], window: window())
        XCTAssertEqual(row(rows, cal: "a", task: "alpha", date: "2026-07-07")?.durationSeconds,
                       2 * 3600)
        XCTAssertEqual(row(rows, cal: "b", task: "bravo", date: "2026-07-07")?.durationSeconds,
                       2 * 3600)
        XCTAssertEqual(row(rows, cal: "c", task: "charlie", date: "2026-07-07")?.durationSeconds,
                       2 * 3600)
    }

    func testLowerPriorityNeverSubtractsUpward() {
        // C (rank 2) overlaps A (rank 0) entirely; A still counts in full.
        let rows = aggregator.aggregate([
            event("Alpha", "2026-07-07 13:00", "2026-07-07 14:00", calendar: "A", rank: 0),
            event("Charlie", "2026-07-07 12:00", "2026-07-07 18:00", calendar: "C", rank: 2)
        ], window: window())
        XCTAssertEqual(row(rows, cal: "a", task: "alpha", date: "2026-07-07")?.durationSeconds,
                       3600)
        XCTAssertEqual(row(rows, cal: "c", task: "charlie", date: "2026-07-07")?.durationSeconds,
                       5 * 3600)
    }

    func testFullySubtractedEventStillCountsOccurrence() {
        // Instagram fully covers Swim → 0 duration, but the occurrence remains.
        let rows = aggregator.aggregate([
            event("Swim", "2026-07-07 14:00", "2026-07-07 15:00", calendar: "Personal", rank: 1),
            event("Instagram", "2026-07-07 12:00", "2026-07-07 18:00",
                  calendar: "Instagram", rank: 0)
        ], window: window())
        let swim = row(rows, cal: "personal", task: "swim", date: "2026-07-07")
        XCTAssertEqual(swim?.durationSeconds, 0)
        XCTAssertEqual(swim?.occurrenceCount, 1)
    }

    func testOverlapCrossingMidnightSubtractsAcrossDays() {
        // Swim 22:00–02:00 (2h+2h). Instagram 23:00–01:00 outranks it.
        // Remaining: 22–23 (1h day7) and 01–02 (1h day8).
        let rows = aggregator.aggregate([
            event("Swim", "2026-07-07 22:00", "2026-07-08 02:00", calendar: "Personal", rank: 1),
            event("Instagram", "2026-07-07 23:00", "2026-07-08 01:00",
                  calendar: "Instagram", rank: 0)
        ], window: window())
        XCTAssertEqual(row(rows, cal: "personal", task: "swim", date: "2026-07-07")?.durationSeconds,
                       3600)
        XCTAssertEqual(row(rows, cal: "personal", task: "swim", date: "2026-07-08")?.durationSeconds,
                       3600)
        // Occurrence stays on the start day only.
        XCTAssertEqual(row(rows, cal: "personal", task: "swim", date: "2026-07-07")?.occurrenceCount, 1)
        XCTAssertEqual(row(rows, cal: "personal", task: "swim", date: "2026-07-08")?.occurrenceCount, 0)
    }

    func testEqualRankEventsDoNotSubtractFromEachOther() {
        // Two overlapping events at the same rank — the default for anything
        // outside the allowlist — each count in full.
        let rows = aggregator.aggregate([
            event("Instagram", "2026-07-07 12:00", "2026-07-07 15:00", calendar: "Instagram"),
            event("News", "2026-07-07 14:00", "2026-07-07 16:00", calendar: "Distraction")
        ], window: window())
        XCTAssertEqual(row(rows, cal: "instagram", task: "instagram", date: "2026-07-07")?.durationSeconds,
                       3 * 3600)
        XCTAssertEqual(row(rows, cal: "distraction", task: "news", date: "2026-07-07")?.durationSeconds,
                       2 * 3600)
    }

    func testEventsInTheSameCalendarDoNotSubtractFromEachOther() {
        // Same calendar → same rank, so two overlapping meetings both count.
        let rows = aggregator.aggregate([
            event("Standup", "2026-07-07 12:00", "2026-07-07 13:00", calendar: "Work", rank: 0),
            event("Review", "2026-07-07 12:30", "2026-07-07 13:30", calendar: "Work", rank: 0)
        ], window: window())
        XCTAssertEqual(row(rows, cal: "work", task: "standup", date: "2026-07-07")?.durationSeconds,
                       3600)
        XCTAssertEqual(row(rows, cal: "work", task: "review", date: "2026-07-07")?.durationSeconds,
                       3600)
    }
}

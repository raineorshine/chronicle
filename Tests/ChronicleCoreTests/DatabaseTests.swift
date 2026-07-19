import XCTest
@testable import ChronicleCore

final class DatabaseTests: XCTestCase {

    private func makeDB() throws -> Database {
        let path = NSTemporaryDirectory() + "chronicle-test-\(UUID().uuidString).db"
        return try Database(path: path)
    }

    private func row(_ date: String,
                     cal: String = "work",
                     task: String = "em",
                     sub: String? = nil,
                     color: String? = nil,
                     seconds: Int,
                     count: Int) -> DailyRow {
        DailyRow(date: date,
                 calendarKey: cal, calendarLabel: cal.capitalized, calendarColor: color,
                 taskKey: task, taskLabel: task,
                 subtaskKey: sub, subtaskLabel: sub,
                 durationSeconds: seconds, occurrenceCount: count)
    }

    func testReplaceWindowAndTotals() throws {
        let db = try makeDB()
        try db.replaceWindow(rows: [
            row("2026-07-07", task: "em", sub: nil, seconds: 3600, count: 1),
            row("2026-07-07", task: "em", sub: "accounting", seconds: 1800, count: 1),
            row("2026-07-08", task: "em", sub: "accounting", seconds: 3600, count: 1)
        ], firstDate: "2026-07-01", lastDate: "2026-07-31")

        // Task-level rollup includes the subtask rows.
        let taskTotals = try db.totals(
            selection: HierarchySelection(calendarKey: "work", taskKey: "em"),
            from: "2026-07-01", to: "2026-07-31")
        XCTAssertEqual(taskTotals.totalHours, (3600 + 1800 + 3600) / 3600.0, accuracy: 0.0001)
        XCTAssertEqual(taskTotals.occurrences, 3)

        // Subtask-level filter isolates the subtask rows.
        let subTotals = try db.totals(
            selection: HierarchySelection(calendarKey: "work", taskKey: "em", subtaskKey: "accounting"),
            from: "2026-07-01", to: "2026-07-31")
        XCTAssertEqual(subTotals.totalHours, (1800 + 3600) / 3600.0, accuracy: 0.0001)
        XCTAssertEqual(subTotals.occurrences, 2)
    }

    func testRebuildIsIdempotentForWindow() throws {
        let db = try makeDB()
        let rows = [row("2026-07-07", seconds: 3600, count: 1)]
        try db.replaceWindow(rows: rows, firstDate: "2026-07-01", lastDate: "2026-07-31")
        try db.replaceWindow(rows: rows, firstDate: "2026-07-01", lastDate: "2026-07-31")
        let totals = try db.totals(selection: .all, from: "2026-07-01", to: "2026-07-31")
        XCTAssertEqual(totals.occurrences, 1) // not doubled
    }

    func testDailySeriesOrdered() throws {
        let db = try makeDB()
        try db.replaceWindow(rows: [
            row("2026-07-09", seconds: 3600, count: 1),
            row("2026-07-07", seconds: 7200, count: 1)
        ], firstDate: "2026-07-01", lastDate: "2026-07-31")
        let series = try db.dailySeries(selection: .all, from: "2026-07-01", to: "2026-07-31")
        XCTAssertEqual(series.map { $0.date }, ["2026-07-07", "2026-07-09"])
        XCTAssertEqual(series[0].hours, 2.0, accuracy: 0.0001)
    }

    func testHierarchyTree() throws {
        let db = try makeDB()
        try db.replaceWindow(rows: [
            row("2026-07-07", cal: "work", task: "em", sub: nil, seconds: 3600, count: 1),
            row("2026-07-07", cal: "work", task: "em", sub: "accounting", seconds: 1800, count: 1),
            row("2026-07-07", cal: "personal", task: "code reviews", sub: nil, seconds: 3600, count: 1)
        ], firstDate: "2026-07-01", lastDate: "2026-07-31")

        let tree = try db.hierarchy()
        XCTAssertEqual(tree.count, 2)
        let work = tree.first { $0.key == "work" }
        XCTAssertEqual(work?.tasks.count, 1)
        XCTAssertEqual(work?.tasks.first?.subtasks.map { $0.key }, ["accounting"])
    }

    func testCalendarColorRoundTripAndPerCalendarSeries() throws {
        let db = try makeDB()
        try db.replaceWindow(rows: [
            row("2026-07-07", cal: "work", task: "em", color: "#FF9500", seconds: 3600, count: 1),
            row("2026-07-07", cal: "personal", task: "gym", color: "#34C759", seconds: 1800, count: 1)
        ], firstDate: "2026-07-01", lastDate: "2026-07-31")

        // Per-calendar series returns one point per (date, calendar) with color.
        let series = try db.dailySeriesByCalendar(selection: .all,
                                                  from: "2026-07-01", to: "2026-07-31")
        XCTAssertEqual(series.count, 2)
        let work = series.first { $0.calendarKey == "work" }
        let personal = series.first { $0.calendarKey == "personal" }
        XCTAssertEqual(work?.colorHex, "#FF9500")
        XCTAssertEqual(work?.hours ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(personal?.colorHex, "#34C759")
        XCTAssertEqual(personal?.hours ?? 0, 0.5, accuracy: 0.0001)

        // Colors also surface on the hierarchy tree.
        let tree = try db.hierarchy()
        XCTAssertEqual(tree.first { $0.key == "work" }?.colorHex, "#FF9500")
        XCTAssertEqual(tree.first { $0.key == "personal" }?.colorHex, "#34C759")
    }
}

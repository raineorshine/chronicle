import XCTest
@testable import ChronicleCore

final class SegmentQueryTests: XCTestCase {

    private func makeDB() throws -> Database {
        let path = NSTemporaryDirectory() + "chronicle-seg-\(UUID().uuidString).db"
        return try Database(path: path)
    }

    private func row(_ date: String,
                     cal: String,
                     task: String,
                     taskLabel: String? = nil,
                     sub: String? = nil,
                     seconds: Int) -> DailyRow {
        DailyRow(date: date,
                 calendarKey: cal, calendarLabel: cal.capitalized, calendarColor: nil,
                 taskKey: task, taskLabel: taskLabel ?? task,
                 subtaskKey: sub, subtaskLabel: sub,
                 durationSeconds: seconds, occurrenceCount: 1)
    }

    func testTaskDimensionMergesAcrossCalendars() throws {
        let db = try makeDB()
        try db.replaceWindow(rows: [
            row("2026-07-06", cal: "work", task: "em", seconds: 3600),          // 1h
            row("2026-07-06", cal: "work", task: "em", sub: "accounting", seconds: 1800), // +0.5h same task
            row("2026-07-06", cal: "personal", task: "em", seconds: 1800),      // +0.5h same task, other calendar
            row("2026-07-06", cal: "personal", task: "gym", seconds: 1800)      // 0.5h
        ], firstDate: "2026-07-01", lastDate: "2026-07-31")

        let points = try db.segmentDailySeries(selection: .all, dimension: .task,
                                               from: "2026-07-01", to: "2026-07-31")

        let em = points.first { $0.segmentKey == "em" }
        let gym = points.first { $0.segmentKey == "gym" }
        // "em" merges across both calendars (1 + 0.5 + 0.5 = 2h).
        XCTAssertEqual(em?.hours ?? 0, 2.0, accuracy: 0.0001)
        XCTAssertEqual(em?.segmentLabel, "em")
        XCTAssertEqual(gym?.hours ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(points.count, 2)
    }

    func testSubtaskDimensionIncludesNoSubtaskBucket() throws {
        let db = try makeDB()
        try db.replaceWindow(rows: [
            row("2026-07-06", cal: "work", task: "em", seconds: 3600),                    // no subtask, 1h
            row("2026-07-06", cal: "work", task: "em", sub: "accounting", seconds: 1800), // 0.5h
            row("2026-07-06", cal: "work", task: "other", seconds: 7200)                  // different task, excluded
        ], firstDate: "2026-07-01", lastDate: "2026-07-31")

        let points = try db.segmentDailySeries(
            selection: HierarchySelection(calendarKey: "work", taskKey: "em"),
            dimension: .subtask, from: "2026-07-01", to: "2026-07-31")

        let none = points.first { $0.segmentKey == SegmentDailyPoint.noSubtaskKey }
        let accounting = points.first { $0.segmentKey == "accounting" }
        XCTAssertEqual(none?.hours ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(none?.segmentLabel, "(no subtask)")
        XCTAssertEqual(accounting?.hours ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(points.count, 2) // "other" task is filtered out by scope
    }

    func testCalendarScopeFiltersTasks() throws {
        let db = try makeDB()
        try db.replaceWindow(rows: [
            row("2026-07-06", cal: "work", task: "em", seconds: 3600),
            row("2026-07-06", cal: "personal", task: "gym", seconds: 3600)
        ], firstDate: "2026-07-01", lastDate: "2026-07-31")

        let points = try db.segmentDailySeries(
            selection: HierarchySelection(calendarKey: "work"),
            dimension: .task, from: "2026-07-01", to: "2026-07-31")

        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.segmentKey, "em")
    }

    func testTaskSummariesMergeAcrossCalendarsAndRank() throws {
        let db = try makeDB()
        try db.replaceWindow(rows: [
            row("2026-07-06", cal: "work", task: "em", seconds: 3600),                     // 1h
            row("2026-07-06", cal: "personal", task: "em", sub: "accounting", seconds: 1800), // +0.5h, subtask
            row("2026-07-06", cal: "work", task: "em", sub: "accounting", seconds: 1800),  // +0.5h, same subtask other cal
            row("2026-07-06", cal: "personal", task: "gym", seconds: 5400),                // 1.5h, no subtask
            row("2026-05-01", cal: "work", task: "old", seconds: 7200)                     // outside window
        ], firstDate: "2026-05-01", lastDate: "2026-07-31")

        let tasks = try db.taskSummaries(from: "2026-07-01", to: "2026-07-31")

        // "old" is filtered out by the window; two tasks remain, gym before em? em=2h, gym=1.5h.
        XCTAssertEqual(tasks.map { $0.key }, ["em", "gym"]) // sorted by hours desc
        let em = tasks.first { $0.key == "em" }
        XCTAssertEqual(em?.hours ?? 0, 2.0, accuracy: 0.0001) // 1 + 0.5 + 0.5 across calendars
        XCTAssertEqual(em?.subtasks.count, 1)
        XCTAssertEqual(em?.subtasks.first?.key, "accounting")
        XCTAssertEqual(em?.subtasks.first?.hours ?? 0, 1.0, accuracy: 0.0001) // merged 0.5 + 0.5
        let gym = tasks.first { $0.key == "gym" }
        XCTAssertEqual(gym?.hours ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertTrue(gym?.subtasks.isEmpty ?? false)
    }
}

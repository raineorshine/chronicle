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

    func testActivityCalendarDailySeriesGroupsByTaskAndCalendar() throws {
        let db = try makeDB()
        try db.replaceWindow(rows: [
            DailyRow(date: "2026-07-06", calendarKey: "work", calendarLabel: "Work",
                     calendarColor: "#111111", taskKey: "em", taskLabel: "⚙️ em",
                     subtaskKey: nil, subtaskLabel: nil, durationSeconds: 3600, occurrenceCount: 1),
            // Same task+calendar, different subtask -> merged into one (task,calendar) row.
            DailyRow(date: "2026-07-06", calendarKey: "work", calendarLabel: "Work",
                     calendarColor: "#111111", taskKey: "em", taskLabel: "⚙️ em",
                     subtaskKey: "accounting", subtaskLabel: "accounting",
                     durationSeconds: 1800, occurrenceCount: 1),
            // Same task, different calendar -> separate (task,calendar) row.
            DailyRow(date: "2026-07-06", calendarKey: "personal", calendarLabel: "Personal",
                     calendarColor: "#222222", taskKey: "em", taskLabel: "⚙️ em",
                     subtaskKey: nil, subtaskLabel: nil, durationSeconds: 1800, occurrenceCount: 1),
        ], firstDate: "2026-07-01", lastDate: "2026-07-31")

        let points = try db.activityCalendarDailySeries(from: "2026-07-01", to: "2026-07-31")

        let work = points.first { $0.calendarKey == "work" }
        let personal = points.first { $0.calendarKey == "personal" }
        XCTAssertEqual(points.count, 2) // (em, work) and (em, personal)
        XCTAssertEqual(work?.hours ?? 0, 1.5, accuracy: 0.0001) // 1h + 0.5h subtasks merged
        XCTAssertEqual(work?.calendarColorHex, "#111111")
        XCTAssertEqual(work?.taskLabel, "⚙️ em")
        XCTAssertEqual(personal?.hours ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(personal?.calendarColorHex, "#222222")
    }

    func testTaskSummariesConsolidateEmojiVariantsUsingMostRecentLabel() throws {
        let db = try makeDB()
        // Same activity ("walk") logged with different emoji on different dates.
        try db.replaceWindow(rows: [
            row("2026-07-06", cal: "health", task: "walk", taskLabel: "🚶Walk", seconds: 3600),
            row("2026-07-13", cal: "health", task: "walk", taskLabel: "👟Walk", seconds: 1800)
        ], firstDate: "2026-07-01", lastDate: "2026-07-31")

        let tasks = try db.taskSummaries(from: "2026-07-01", to: "2026-07-31")

        // Emoji variants collapse to a single task, hours summed across them.
        XCTAssertEqual(tasks.count, 1)
        let walk = tasks.first
        XCTAssertEqual(walk?.key, "walk")
        XCTAssertEqual(walk?.hours ?? 0, 1.5, accuracy: 0.0001) // 1h + 0.5h
        // The most recent occurrence's emoji wins.
        XCTAssertEqual(walk?.label, "👟Walk")
    }

    func testTaskSummariesSubtaskUsesMostRecentEmojiLabel() throws {
        let db = try makeDB()
        try db.replaceWindow(rows: [
            row("2026-07-06", cal: "health", task: "walk", taskLabel: "🚶Walk",
                sub: "dog", seconds: 3600),
            row("2026-07-13", cal: "health", task: "walk", taskLabel: "👟Walk",
                sub: "dog", seconds: 1800)
        ], firstDate: "2026-07-01", lastDate: "2026-07-31")

        let tasks = try db.taskSummaries(from: "2026-07-01", to: "2026-07-31")
        let walk = tasks.first { $0.key == "walk" }
        XCTAssertEqual(walk?.label, "👟Walk")
        XCTAssertEqual(walk?.subtasks.count, 1)
        XCTAssertEqual(walk?.subtasks.first?.key, "dog")
        XCTAssertEqual(walk?.subtasks.first?.label, "dog")
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

    func testTaskSummariesWindowMembershipWithCurrentWeekHours() throws {
        let db = try makeDB()
        // Window = 2026-07-06 .. 2026-07-19; current week = 2026-07-13 .. 2026-07-19.
        try db.replaceWindow(rows: [
            // "old" activity: only active in an earlier window week (idle this week).
            row("2026-07-08", cal: "work", task: "old", seconds: 7200),                  // 2h last week
            // "em": some last week, more this week; a subtask only this week.
            row("2026-07-09", cal: "work", task: "em", seconds: 3600),                   // 1h last week (ignored)
            row("2026-07-14", cal: "work", task: "em", seconds: 1800),                   // 0.5h this week
            row("2026-07-15", cal: "personal", task: "em", sub: "accounting", seconds: 1800), // 0.5h this week, subtask
            // "gym": only this week.
            row("2026-07-16", cal: "personal", task: "gym", seconds: 3600)              // 1h this week
        ], firstDate: "2026-07-06", lastDate: "2026-07-19")

        let tasks = try db.taskSummaries(windowFrom: "2026-07-06", windowTo: "2026-07-19",
                                         hoursFrom: "2026-07-13", hoursTo: "2026-07-19")

        // All three window activities are listed; sorted by current-week hours desc,
        // so the idle-this-week "old" sinks to the bottom with 0h.
        XCTAssertEqual(tasks.map { $0.key }, ["em", "gym", "old"])

        let em = tasks.first { $0.key == "em" }
        XCTAssertEqual(em?.hours ?? -1, 1.0, accuracy: 0.0001) // 0.5 + 0.5 this week only
        XCTAssertEqual(em?.subtasks.count, 1)
        XCTAssertEqual(em?.subtasks.first?.key, "accounting")
        XCTAssertEqual(em?.subtasks.first?.hours ?? -1, 0.5, accuracy: 0.0001)

        let gym = tasks.first { $0.key == "gym" }
        XCTAssertEqual(gym?.hours ?? -1, 1.0, accuracy: 0.0001)

        let old = tasks.first { $0.key == "old" }
        XCTAssertEqual(old?.hours ?? -1, 0.0, accuracy: 0.0001) // present in window, idle this week
        XCTAssertTrue(old?.subtasks.isEmpty ?? false)
    }
}

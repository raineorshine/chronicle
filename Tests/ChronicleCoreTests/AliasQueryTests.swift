import XCTest
@testable import ChronicleCore

final class AliasQueryTests: XCTestCase {

    private func makeDB() throws -> Database {
        let path = NSTemporaryDirectory() + "chronicle-alias-\(UUID().uuidString).db"
        return try Database(path: path)
    }

    private func row(_ date: String,
                     cal: String = "work",
                     task: String,
                     taskLabel: String? = nil,
                     sub: String? = nil,
                     subLabel: String? = nil,
                     seconds: Int) -> DailyRow {
        DailyRow(date: date,
                 calendarKey: cal, calendarLabel: cal.capitalized, calendarColor: nil,
                 taskKey: task, taskLabel: taskLabel ?? task,
                 subtaskKey: sub, subtaskLabel: subLabel ?? sub,
                 durationSeconds: seconds, occurrenceCount: 1)
    }

    // MARK: - Resolver

    func testResolveChainMapsEarlierTitlesToTerminal() {
        let aliases = AliasResolver.resolve(chains: [[
            "VP of Engineering", "em - Code Reviews", "em - Engineering Lead"
        ]])
        XCTAssertEqual(aliases.count, 2)
        // Every non-terminal entry points at the last (canonical) title.
        for a in aliases {
            XCTAssertEqual(a.toTaskKey, "em")
            XCTAssertEqual(a.toSubtaskKey, "engineering lead")
            XCTAssertEqual(a.toSubtaskLabel, "Engineering Lead")
        }
        XCTAssertTrue(aliases.contains {
            $0.fromTaskKey == "vp of engineering" && $0.fromSubtaskKey == nil
        })
        XCTAssertTrue(aliases.contains {
            $0.fromTaskKey == "em" && $0.fromSubtaskKey == "code reviews"
        })
    }

    func testResolveSkipsSelfMapsAndShortChains() {
        XCTAssertTrue(AliasResolver.resolve(chains: [["em"]]).isEmpty)          // single entry
        XCTAssertTrue(AliasResolver.resolve(chains: [["em", "em"]]).isEmpty)    // maps to itself
        XCTAssertTrue(AliasResolver.resolve(chains: [["", "em"]]).isEmpty)      // unparseable head
    }

    // MARK: - Read-time canonicalization

    func testBareTaskMergesIntoTaskSubtask() throws {
        let db = try makeDB()
        try db.replaceWindow(rows: [
            row("2026-07-06", task: "vp of engineering", taskLabel: "VP of Engineering", seconds: 3600), // 1h bare
            row("2026-07-06", task: "em", sub: "code reviews", subLabel: "Code Reviews", seconds: 1800)  // 0.5h
        ], firstDate: "2026-07-01", lastDate: "2026-07-31")
        try db.setAliases(AliasResolver.resolve(chains: [["VP of Engineering", "em - Code Reviews"]]))

        // Top-level task segmentation: everything folds into "em".
        let tasks = try db.segmentDailySeries(selection: .all, dimension: .task,
                                              from: "2026-07-01", to: "2026-07-31")
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.segmentKey, "em")
        XCTAssertEqual(tasks.first?.hours ?? 0, 1.5, accuracy: 0.0001)

        // Drilling into "em" by subtask shows the merged hours under "Code Reviews".
        let subs = try db.segmentDailySeries(selection: HierarchySelection(taskKey: "em"),
                                             dimension: .subtask,
                                             from: "2026-07-01", to: "2026-07-31")
        XCTAssertEqual(subs.count, 1)
        XCTAssertEqual(subs.first?.segmentKey, "code reviews")
        XCTAssertEqual(subs.first?.segmentLabel, "Code Reviews")
        XCTAssertEqual(subs.first?.hours ?? 0, 1.5, accuracy: 0.0001)
    }

    func testThreeTitleChainCollapsesToTerminal() throws {
        let db = try makeDB()
        try db.replaceWindow(rows: [
            row("2026-07-06", task: "vp of engineering", taskLabel: "VP of Engineering", seconds: 3600),
            row("2026-07-06", task: "em", sub: "code reviews", subLabel: "Code Reviews", seconds: 3600),
            row("2026-07-06", task: "em", sub: "engineering lead", subLabel: "Engineering Lead", seconds: 3600)
        ], firstDate: "2026-07-01", lastDate: "2026-07-31")
        try db.setAliases(AliasResolver.resolve(chains: [[
            "VP of Engineering", "em - Code Reviews", "em - Engineering Lead"
        ]]))

        let subs = try db.segmentDailySeries(selection: HierarchySelection(taskKey: "em"),
                                             dimension: .subtask,
                                             from: "2026-07-01", to: "2026-07-31")
        XCTAssertEqual(subs.count, 1)
        XCTAssertEqual(subs.first?.segmentKey, "engineering lead")
        XCTAssertEqual(subs.first?.hours ?? 0, 3.0, accuracy: 0.0001)

        // Occurrences merge too: 3 events under one canonical activity.
        let totals = try db.totals(selection: HierarchySelection(taskKey: "em"),
                                   from: "2026-07-01", to: "2026-07-31")
        XCTAssertEqual(totals.occurrences, 3)
    }

    func testExactTitleMatchLeavesSubtaskedVariantAlone() throws {
        let db = try makeDB()
        try db.replaceWindow(rows: [
            // A subtasked variant of the aliased bare task must NOT be remapped.
            row("2026-07-06", task: "vp of engineering", sub: "accounting", seconds: 3600)
        ], firstDate: "2026-07-01", lastDate: "2026-07-31")
        try db.setAliases(AliasResolver.resolve(chains: [["VP of Engineering", "em - Code Reviews"]]))

        let tasks = try db.segmentDailySeries(selection: .all, dimension: .task,
                                              from: "2026-07-01", to: "2026-07-31")
        XCTAssertEqual(tasks.first?.segmentKey, "vp of engineering")
        XCTAssertNil(tasks.first { $0.segmentKey == "em" })
    }

    func testEmptyAliasMapIsPassThrough() throws {
        let db = try makeDB()
        try db.replaceWindow(rows: [
            row("2026-07-06", task: "em", seconds: 3600)
        ], firstDate: "2026-07-01", lastDate: "2026-07-31")
        // No setAliases call: canonical_time should mirror daily_time.
        let tasks = try db.segmentDailySeries(selection: .all, dimension: .task,
                                              from: "2026-07-01", to: "2026-07-31")
        XCTAssertEqual(tasks.first?.segmentKey, "em")
        XCTAssertEqual(tasks.first?.hours ?? 0, 1.0, accuracy: 0.0001)
    }

    func testTaskSummariesReflectMergedIdentity() throws {
        let db = try makeDB()
        try db.replaceWindow(rows: [
            row("2026-07-06", task: "vp of engineering", taskLabel: "VP of Engineering", seconds: 3600),
            row("2026-07-06", task: "em", sub: "code reviews", subLabel: "Code Reviews", seconds: 1800)
        ], firstDate: "2026-07-01", lastDate: "2026-07-31")
        try db.setAliases(AliasResolver.resolve(chains: [["VP of Engineering", "em - Code Reviews"]]))

        let summaries = try db.taskSummaries(from: "2026-07-01", to: "2026-07-31")
        XCTAssertEqual(summaries.count, 1)
        let em = summaries.first
        XCTAssertEqual(em?.key, "em")
        XCTAssertEqual(em?.hours ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(em?.subtasks.first?.label, "Code Reviews")
        XCTAssertEqual(em?.subtasks.first?.hours ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertNil(summaries.first { $0.key == "vp of engineering" })
    }

    func testSetAliasesReplacesPreviousSet() throws {
        let db = try makeDB()
        try db.replaceWindow(rows: [
            row("2026-07-06", task: "vp of engineering", seconds: 3600)
        ], firstDate: "2026-07-01", lastDate: "2026-07-31")

        try db.setAliases(AliasResolver.resolve(chains: [["VP of Engineering", "em"]]))
        var tasks = try db.segmentDailySeries(selection: .all, dimension: .task,
                                              from: "2026-07-01", to: "2026-07-31")
        XCTAssertEqual(tasks.first?.segmentKey, "em")

        // Clearing aliases restores the original identity.
        try db.setAliases([])
        tasks = try db.segmentDailySeries(selection: .all, dimension: .task,
                                          from: "2026-07-01", to: "2026-07-31")
        XCTAssertEqual(tasks.first?.segmentKey, "vp of engineering")
    }
}

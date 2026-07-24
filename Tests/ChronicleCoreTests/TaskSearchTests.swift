import XCTest
@testable import ChronicleCore

final class TaskSearchTests: XCTestCase {

    private func task(_ label: String,
                      hours: Double = 1,
                      subtasks: [(String, Double)] = []) -> TaskSummary {
        TaskSummary(key: label.lowercased(),
                    label: label,
                    hours: hours,
                    subtasks: subtasks.map {
                        SubtaskSummary(key: $0.0.lowercased(), label: $0.0, hours: $0.1)
                    })
    }

    // MARK: - Matching

    func testBlankQueryMatchesNothing() {
        let tasks = [task("Engineering")]
        XCTAssertTrue(TaskSearch.match("", in: tasks).isEmpty)
        XCTAssertTrue(TaskSearch.match("   ", in: tasks).isEmpty)
    }

    func testMatchIsCaseAndDiacriticInsensitive() {
        let tasks = [task("Café Réunion")]
        XCTAssertEqual(TaskSearch.match("cafe", in: tasks).map(\.displayLabel),
                       ["Café Réunion"])
        XCTAssertEqual(TaskSearch.match("REUNION", in: tasks).map(\.displayLabel),
                       ["Café Réunion"])
    }

    func testNoMatchReturnsEmpty() {
        XCTAssertTrue(TaskSearch.match("zzz", in: [task("Engineering")]).isEmpty)
    }

    // MARK: - Ranking

    func testPrefixOutranksMidWordSubstring() {
        // Both contain "eng", but only one starts with it. The mid-word hit has
        // far more hours, so rank must win over hours.
        let tasks = [task("Reengineering", hours: 50), task("Engineering", hours: 1)]
        XCTAssertEqual(TaskSearch.match("eng", in: tasks).map(\.displayLabel),
                       ["Engineering", "Reengineering"])
    }

    func testWordBoundaryOutranksMidWordSubstring() {
        let tasks = [task("Reengineering", hours: 50), task("Deep Engineering", hours: 1)]
        XCTAssertEqual(TaskSearch.match("eng", in: tasks).map(\.displayLabel),
                       ["Deep Engineering", "Reengineering"])
    }

    func testHoursBreakTiesWithinARank() {
        let tasks = [task("Design", hours: 2), task("Design Review", hours: 9)]
        XCTAssertEqual(TaskSearch.match("des", in: tasks).map(\.displayLabel),
                       ["Design Review", "Design"])
    }

    func testTaskOutranksItsOwnSubtaskAtEqualQuality() {
        let tasks = [task("em", hours: 1, subtasks: [("emails", 40)])]
        XCTAssertEqual(TaskSearch.match("em", in: tasks).map(\.displayLabel),
                       ["em", "em / emails"])
    }

    // MARK: - Subtasks

    func testSubtaskFoundByItsOwnName() {
        let tasks = [task("em", subtasks: [("Code Reviews", 3)])]
        let results = TaskSearch.match("code", in: tasks)
        XCTAssertEqual(results.map(\.displayLabel), ["em / Code Reviews"])
        XCTAssertEqual(results.first?.taskKey, "em")
        XCTAssertEqual(results.first?.subtaskKey, "code reviews")
        XCTAssertEqual(results.first?.hours, 3)
    }

    func testSubtaskFoundByTaskAndSubtaskTogether() {
        let tasks = [task("em", subtasks: [("Code Reviews", 3)])]
        XCTAssertEqual(TaskSearch.match("em code", in: tasks).map(\.displayLabel),
                       ["em / Code Reviews"])
    }

    // MARK: - Result shape

    func testNodeIDsMatchSidebarConvention() {
        let tasks = [task("em", subtasks: [("Code Reviews", 3)])]
        XCTAssertEqual(TaskSearch.match("em", in: tasks).map(\.id),
                       ["task:em", "sub:em:code reviews"])
    }

    // MARK: - Default suggestions

    func testTopActivitiesKeepsSidebarOrderAndSkipsSubtasks() {
        let tasks = [task("Engineering", hours: 9, subtasks: [("Reviews", 4)]),
                     task("Reading", hours: 3)]
        let top = TaskSearch.topActivities(in: tasks)
        XCTAssertEqual(top.map(\.displayLabel), ["Engineering", "Reading"])
        XCTAssertEqual(top.map(\.id), ["task:engineering", "task:reading"])
    }

    func testTopActivitiesRespectsLimit() {
        let tasks = (1...12).map { task("Task \($0)") }
        XCTAssertEqual(TaskSearch.topActivities(in: tasks).count, 8)
        XCTAssertEqual(TaskSearch.topActivities(in: tasks, limit: 2).count, 2)
    }

    func testLimitTruncatesResults() {
        let tasks = (1...12).map { task("Task \($0)", hours: Double($0)) }
        XCTAssertEqual(TaskSearch.match("task", in: tasks).count, 8)
        XCTAssertEqual(TaskSearch.match("task", in: tasks, limit: 3).map(\.displayLabel),
                       ["Task 12", "Task 11", "Task 10"])
    }
}

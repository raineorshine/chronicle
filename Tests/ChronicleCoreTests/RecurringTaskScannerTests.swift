import XCTest
@testable import ChronicleCore

final class RecurringTaskScannerTests: XCTestCase {

    private func occurrence(_ title: String,
                            allDay: Bool = false,
                            recurring: Bool = true) -> UpcomingOccurrence {
        UpcomingOccurrence(rawTitle: title, isAllDay: allDay, isRecurring: recurring)
    }

    private func task(_ key: String) -> TaskIdentity {
        TaskIdentity(taskKey: key)
    }

    private func subtask(_ key: String, of taskKey: String) -> TaskIdentity {
        TaskIdentity(taskKey: taskKey, subtaskKey: key)
    }

    func testCollectsRecurringTasks() {
        let found = RecurringTaskScanner.identities(in: [occurrence("Email"),
                                                         occurrence("Standup")])

        XCTAssertEqual(found, [task("email"), task("standup")])
    }

    func testIgnoresNonRecurringEvents() {
        let found = RecurringTaskScanner.identities(in: [occurrence("Email", recurring: false),
                                                         occurrence("Standup")])

        XCTAssertEqual(found, [task("standup")])
    }

    func testAllDayEventsNeverCount() {
        // The extractor skips all-day events, so they never form a task.
        let found = RecurringTaskScanner.identities(in: [occurrence("Email", allDay: true)])

        XCTAssertTrue(found.isEmpty)
    }

    func testSubtaskedTitlesMarkBothLevels() {
        // The event's hours land on both sidebar rows, so both are marked.
        let found = RecurringTaskScanner.identities(in: [occurrence("Email - Reply")])

        XCTAssertEqual(found, [task("email"), subtask("reply", of: "email")])
    }

    func testSiblingSubtasksAreMarkedIndependently() {
        // Only the recurring subtask is marked, while their shared task is too.
        let found = RecurringTaskScanner.identities(in: [occurrence("Email - Reply"),
                                                         occurrence("Email - Triage",
                                                                    recurring: false)])

        XCTAssertEqual(found, [task("email"), subtask("reply", of: "email")])
    }

    func testHonorsConfiguredSeparators() {
        // With ` - ` not configured as a separator, the whole title is one task.
        let found = RecurringTaskScanner.identities(in: [occurrence("Email - Reply")],
                                                    separators: [" | "])

        XCTAssertEqual(found, [task("email reply")])
    }

    func testUnparseableTitlesAreSkipped() {
        let found = RecurringTaskScanner.identities(in: [occurrence("   "),
                                                         occurrence("Email")])

        XCTAssertEqual(found, [task("email")])
    }
}

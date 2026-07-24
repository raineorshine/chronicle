import XCTest
@testable import ChronicleCore

final class TaskReplacementPlannerTests: XCTestCase {

    /// Fixed base date so occurrence ordering is deterministic.
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func day(_ offset: Int) -> Date {
        base.addingTimeInterval(TimeInterval(offset) * 86_400)
    }

    private func candidate(_ id: String,
                           title: String,
                           allDay: Bool = false,
                           recurring: Bool = false,
                           editable: Bool = true,
                           start: Date? = nil) -> ReplacementCandidate {
        ReplacementCandidate(occurrenceID: id,
                             rawTitle: title,
                             isAllDay: allDay,
                             isRecurring: recurring,
                             allowsModification: editable,
                             occurrenceStart: start ?? base)
    }

    // MARK: - Matching

    func testMatchesPlainTitleAndIgnoresOtherTasks() {
        let plan = TaskReplacementPlanner.plan(
            candidates: [candidate("a", title: "Email"),
                         candidate("b", title: "Standup")],
            targetTaskKey: "email")

        XCTAssertEqual(plan.ops.count, 1)
        XCTAssertEqual(plan.ops.first?.occurrenceID, "a")
        XCTAssertEqual(plan.ops.first?.span, .thisEvent)
    }

    func testMatchesSubtaskedTitlesOnTaskKey() {
        // `Email - Reply` parses to task `email`, so it belongs to the task and
        // is replaced along with the bare title.
        let plan = TaskReplacementPlanner.plan(
            candidates: [candidate("a", title: "Email - Reply to Bob"),
                         candidate("b", title: "Email | Triage"),
                         candidate("c", title: "Emailing")],
            targetTaskKey: "email")

        XCTAssertEqual(plan.ops.map(\.occurrenceID), ["a", "b"])
    }

    func testAllDayEventsAreNeverReplaced() {
        // The extractor skips all-day events, so they never form a task.
        let plan = TaskReplacementPlanner.plan(
            candidates: [candidate("a", title: "Email", allDay: true),
                         candidate("b", title: "Email")],
            targetTaskKey: "email")

        XCTAssertEqual(plan.ops.map(\.occurrenceID), ["b"])
    }

    func testUnparseableTitleIsIgnored() {
        let plan = TaskReplacementPlanner.plan(
            candidates: [candidate("a", title: "   "),
                         candidate("b", title: "Email")],
            targetTaskKey: "email")

        XCTAssertEqual(plan.ops.map(\.occurrenceID), ["b"])
    }

    // MARK: - Subtask scoping

    func testSubtaskTargetNarrowsToThatSubtaskOnly() {
        let plan = TaskReplacementPlanner.plan(
            candidates: [candidate("a", title: "Email - Reply"),
                         candidate("b", title: "Email - Triage"),
                         candidate("c", title: "Email")],
            targetTaskKey: "email",
            targetSubtaskKey: "reply")

        XCTAssertEqual(plan.ops.map(\.occurrenceID), ["a"])
    }

    func testSubtaskTargetIgnoresBareTaskEvents() {
        // A bare `Email` has no subtask, so it must not match a subtask target.
        let plan = TaskReplacementPlanner.plan(
            candidates: [candidate("a", title: "Email")],
            targetTaskKey: "email",
            targetSubtaskKey: "reply")

        XCTAssertTrue(plan.ops.isEmpty)
    }

    func testNilSubtaskTargetStillSweepsSubtaskedEvents() {
        // Task-level replacement is deliberately broad: it takes the subtasks too.
        let plan = TaskReplacementPlanner.plan(
            candidates: [candidate("a", title: "Email - Reply"),
                         candidate("b", title: "Email")],
            targetTaskKey: "email",
            targetSubtaskKey: nil)

        XCTAssertEqual(plan.ops.map(\.occurrenceID), ["a", "b"])
    }

    func testSubtaskTargetHonorsRecurringDedupe() {
        let plan = TaskReplacementPlanner.plan(
            candidates: [candidate("s", title: "Email - Reply", recurring: true, start: day(1)),
                         candidate("s", title: "Email - Reply", recurring: true, start: day(0)),
                         candidate("t", title: "Email - Triage", recurring: true, start: day(0))],
            targetTaskKey: "email",
            targetSubtaskKey: "reply")

        XCTAssertEqual(plan.ops.count, 1)
        XCTAssertEqual(plan.ops.first?.candidateIndex, 1)
        XCTAssertEqual(plan.ops.first?.span, .futureEvents)
    }

    // MARK: - Spans

    func testStandaloneEventsEachGetTheirOwnWrite() {
        let plan = TaskReplacementPlanner.plan(
            candidates: [candidate("a", title: "Email", start: day(0)),
                         candidate("b", title: "Email", start: day(1))],
            targetTaskKey: "email")

        XCTAssertEqual(plan.ops.count, 2)
        XCTAssertTrue(plan.ops.allSatisfy { $0.span == .thisEvent })
    }

    func testRecurringOccurrencesCollapseToOneFutureEventsWrite() {
        // All three occurrences share one series identifier; only the earliest
        // is written, with `.futureEvents` covering the rest of the series.
        let plan = TaskReplacementPlanner.plan(
            candidates: [candidate("s", title: "Email", recurring: true, start: day(2)),
                         candidate("s", title: "Email", recurring: true, start: day(0)),
                         candidate("s", title: "Email", recurring: true, start: day(1))],
            targetTaskKey: "email")

        XCTAssertEqual(plan.ops.count, 1)
        XCTAssertEqual(plan.ops.first?.span, .futureEvents)
        // Index 1 holds the day(0) occurrence — the earliest of the three.
        XCTAssertEqual(plan.ops.first?.candidateIndex, 1)
    }

    func testDistinctSeriesEachGetTheirOwnWrite() {
        let plan = TaskReplacementPlanner.plan(
            candidates: [candidate("s1", title: "Email", recurring: true, start: day(0)),
                         candidate("s2", title: "Email - Triage", recurring: true, start: day(1))],
            targetTaskKey: "email")

        XCTAssertEqual(plan.ops.count, 2)
        XCTAssertEqual(Set(plan.ops.map(\.occurrenceID)), ["s1", "s2"])
        XCTAssertTrue(plan.ops.allSatisfy { $0.span == .futureEvents })
    }

    /// Several *distinct* recurring series can share one title, and so count as
    /// one task. Dedupe is keyed by series identifier, not by title, so every
    /// series must get its own `.futureEvents` write — missing the 2nd and 3rd
    /// would silently leave most of the task behind.
    func testDistinctSeriesSharingOneTitleAreAllReplaced() {
        // Three weekly "Event" series, occurrences interleaved in time.
        var candidates: [ReplacementCandidate] = []
        for week in 0..<3 {
            for (offset, series) in ["s1", "s2", "s3"].enumerated() {
                candidates.append(candidate(series,
                                            title: "Event",
                                            recurring: true,
                                            start: day(week * 7 + offset)))
            }
        }

        let plan = TaskReplacementPlanner.plan(candidates: candidates,
                                               targetTaskKey: "event")

        XCTAssertEqual(plan.ops.count, 3)
        XCTAssertEqual(Set(plan.ops.map(\.occurrenceID)), ["s1", "s2", "s3"])
        XCTAssertTrue(plan.ops.allSatisfy { $0.span == .futureEvents })
        // Each series is written at its own earliest occurrence (week 0).
        XCTAssertEqual(plan.ops.map(\.candidateIndex), [0, 1, 2])
    }

    func testRecurringAndStandaloneMix() {
        let plan = TaskReplacementPlanner.plan(
            candidates: [candidate("s", title: "Email", recurring: true, start: day(0)),
                         candidate("one", title: "Email", start: day(1)),
                         candidate("s", title: "Email", recurring: true, start: day(2))],
            targetTaskKey: "email")

        XCTAssertEqual(plan.ops.count, 2)
        // Ops come back ordered by candidate index, so the plan is deterministic.
        XCTAssertEqual(plan.ops.map(\.candidateIndex), [0, 1])
        XCTAssertEqual(plan.ops.map(\.span), [.futureEvents, .thisEvent])
    }

    // MARK: - Read-only calendars

    func testReadOnlyMatchesAreSkippedAndCounted() {
        let plan = TaskReplacementPlanner.plan(
            candidates: [candidate("a", title: "Email", editable: false),
                         candidate("b", title: "Email", recurring: true, editable: false),
                         candidate("c", title: "Email")],
            targetTaskKey: "email")

        XCTAssertEqual(plan.ops.map(\.occurrenceID), ["c"])
        XCTAssertEqual(plan.skippedReadOnly, 2)
    }

    func testReadOnlySeriesCountsOnceNotPerOccurrence() {
        // The skip count is reported to the user in events, like the write plan,
        // so a read-only series must not inflate it by its occurrences.
        let plan = TaskReplacementPlanner.plan(
            candidates: [candidate("s", title: "Email", recurring: true, editable: false, start: day(0)),
                         candidate("s", title: "Email", recurring: true, editable: false, start: day(1)),
                         candidate("s", title: "Email", recurring: true, editable: false, start: day(2)),
                         candidate("one", title: "Email", editable: false, start: day(3)),
                         candidate("two", title: "Email", editable: false, start: day(4))],
            targetTaskKey: "email")

        XCTAssertTrue(plan.ops.isEmpty)
        // One series plus two distinct one-offs.
        XCTAssertEqual(plan.skippedReadOnly, 3)
    }

    func testNonMatchingReadOnlyEventsAreNotCounted() {
        let plan = TaskReplacementPlanner.plan(
            candidates: [candidate("a", title: "Standup", editable: false)],
            targetTaskKey: "email")

        XCTAssertTrue(plan.ops.isEmpty)
        XCTAssertEqual(plan.skippedReadOnly, 0)
    }

    // MARK: - Separators

    func testRespectsConfiguredSeparators() {
        // With only `::` as a separator, ` - ` is part of the task title itself.
        let plan = TaskReplacementPlanner.plan(
            candidates: [candidate("a", title: "Email - Reply")],
            targetTaskKey: "email",
            separators: ["::"])

        XCTAssertTrue(plan.ops.isEmpty)

        let matching = TaskReplacementPlanner.plan(
            candidates: [candidate("a", title: "Email - Reply")],
            targetTaskKey: "email reply",
            separators: ["::"])

        XCTAssertEqual(matching.ops.map(\.occurrenceID), ["a"])
    }

    // MARK: - Summary from a plan

    /// `TaskReplacer.preview` turns a plan into the numbers the Replace sheet
    /// shows, so the derivation must count events: one per series, one per
    /// one-off, never one per occurrence.
    func testSummaryFromPlanCountsEventsNotOccurrences() {
        let plan = TaskReplacementPlanner.plan(
            candidates: [candidate("s1", title: "Email", recurring: true, start: day(0)),
                         candidate("s1", title: "Email", recurring: true, start: day(1)),
                         candidate("s2", title: "Email - Triage", recurring: true, start: day(0)),
                         candidate("one", title: "Email", start: day(2)),
                         candidate("ro", title: "Email", editable: false, start: day(3))],
            targetTaskKey: "email")

        let summary = ReplacementSummary(plan: plan)

        XCTAssertEqual(summary.replacedSeries, 2)
        XCTAssertEqual(summary.replacedStandalone, 1)
        XCTAssertEqual(summary.skippedReadOnly, 1)
        XCTAssertEqual(summary.totalReplaced, 3)
    }

    func testSummaryFromEmptyPlanIsZero() {
        let plan = TaskReplacementPlanner.plan(
            candidates: [candidate("a", title: "Standup")],
            targetTaskKey: "email")

        XCTAssertEqual(ReplacementSummary(plan: plan),
                       ReplacementSummary(replacedSeries: 0,
                                          replacedStandalone: 0,
                                          skippedReadOnly: 0))
    }
}

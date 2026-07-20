import XCTest
@testable import ChronicleCore

final class WeeklyBucketingTests: XCTestCase {

    /// Gregorian, UTC, Monday-start — deterministic week boundaries.
    private func mondayCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 2 // Monday
        return cal
    }

    private func point(_ date: String, _ key: String, _ label: String, _ hours: Double) -> SegmentDailyPoint {
        SegmentDailyPoint(date: date, segmentKey: key, segmentLabel: label, hours: hours)
    }

    private func tcPoint(_ date: String, task: String, taskLabel: String,
                         cal: String, calLabel: String? = nil, color: String? = nil,
                         hours: Double) -> TaskCalendarDailyPoint {
        TaskCalendarDailyPoint(date: date, taskKey: task, taskLabel: taskLabel,
                               calendarKey: cal, calendarLabel: calLabel ?? cal.capitalized,
                               calendarColorHex: color, hours: hours)
    }

    func testEmptyInputProducesEmptyStacks() {
        let stacks = WeeklyBucketing.bucket([], calendar: mondayCalendar())
        XCTAssertEqual(stacks, .empty)
    }

    func testBucketsDaysIntoWeeksAndRanksByTotal() {
        // 2026-07-06 is a Monday; 07-13 is the next Monday.
        let points = [
            point("2026-07-06", "a", "A", 2),
            point("2026-07-08", "a", "A", 1),   // same week as above → A week1 = 3h
            point("2026-07-13", "b", "B", 4)    // week2 → B = 4h
        ]
        let stacks = WeeklyBucketing.bucket(points, calendar: mondayCalendar(), topN: 8)

        XCTAssertEqual(stacks.weekStarts, ["2026-07-06", "2026-07-13"])
        // B (4h) outranks A (3h).
        XCTAssertEqual(stacks.segments.map(\.key), ["b", "a"])

        func hours(_ week: String, _ key: String) -> Double {
            stacks.points.first { $0.weekStart == week && $0.segmentKey == key }?.hours ?? 0
        }
        XCTAssertEqual(hours("2026-07-06", "a"), 3, accuracy: 0.0001)
        XCTAssertEqual(hours("2026-07-13", "b"), 4, accuracy: 0.0001)
        // No cross-week bleed.
        XCTAssertNil(stacks.points.first { $0.weekStart == "2026-07-06" && $0.segmentKey == "b" })
    }

    func testTopNFoldsTailIntoOther() {
        let points = [
            point("2026-07-06", "s1", "One", 5),
            point("2026-07-06", "s2", "Two", 4),
            point("2026-07-06", "s3", "Three", 3),
            point("2026-07-06", "s4", "Four", 2)
        ]
        let stacks = WeeklyBucketing.bucket(points, calendar: mondayCalendar(), topN: 2)

        // Top two kept in order, then a single Other bucket last.
        XCTAssertEqual(stacks.segments.map(\.key), ["s1", "s2", WeeklyBucketing.otherKey])
        XCTAssertTrue(stacks.segments.last?.isOther ?? false)
        XCTAssertEqual(stacks.segments.last?.label, "Other")

        let other = stacks.points.first { $0.segmentKey == WeeklyBucketing.otherKey }
        XCTAssertEqual(other?.hours ?? 0, 5, accuracy: 0.0001) // 3 + 2
        // Overflow segments are not emitted individually.
        XCTAssertNil(stacks.points.first { $0.segmentKey == "s3" })
    }

    func testRespectsFirstWeekday() {
        // 2026-07-05 is a Sunday. With a Sunday-start calendar it opens a week;
        // with a Monday-start calendar it belongs to the prior Monday (06-29).
        var sunday = Calendar(identifier: .gregorian)
        sunday.timeZone = TimeZone(identifier: "UTC")!
        sunday.firstWeekday = 1

        let p = [point("2026-07-05", "a", "A", 1)]
        XCTAssertEqual(WeeklyBucketing.bucket(p, calendar: sunday).weekStarts, ["2026-07-05"])
        XCTAssertEqual(WeeklyBucketing.bucket(p, calendar: mondayCalendar()).weekStarts, ["2026-06-29"])
    }

    // MARK: - Per-calendar segment mode

    func testTaskModeIndividualAndWholeCalendarFolds() {
        let points = [
            // Task-mode calendars -> individual task segments, merged across cals.
            tcPoint("2026-07-06", task: "code reviews", taskLabel: "Code Reviews", cal: "work", hours: 3),
            tcPoint("2026-07-06", task: "code reviews", taskLabel: "Code Reviews", cal: "actual", hours: 1),
            tcPoint("2026-07-06", task: "walk", taskLabel: "Walk", cal: "actual", hours: 2),
            // Whole-calendar mode ("health") -> all its tasks fold into one segment.
            tcPoint("2026-07-06", task: "nemesis", taskLabel: "Nemesis", cal: "health", calLabel: "Health", hours: 1.5),
            tcPoint("2026-07-06", task: "bestia", taskLabel: "Bestia", cal: "health", calLabel: "Health", hours: 0.5),
        ]
        let stacks = WeeklyBucketing.bucketByCalendarSegmentMode(
            points, calendar: mondayCalendar(), wholeCalendarKeys: ["health"])

        let calHealth = WeeklyBucketing.calendarKeyPrefix + "health"
        // Order: task segments alpha (code reviews, walk), then calendar segments.
        XCTAssertEqual(stacks.segments.map(\.key), ["code reviews", "walk", calHealth])

        func hours(_ key: String) -> Double {
            stacks.points.first { $0.weekStart == "2026-07-06" && $0.segmentKey == key }?.hours ?? 0
        }
        XCTAssertEqual(hours("code reviews"), 4, accuracy: 0.0001)  // merged across calendars
        XCTAssertEqual(hours("walk"), 2, accuracy: 0.0001)
        XCTAssertEqual(hours(calHealth), 2, accuracy: 0.0001)       // nemesis + bestia

        // Whole-calendar segments are flagged; task segments are not.
        XCTAssertTrue(stacks.segments.first { $0.key == calHealth }?.isCalendarBucket ?? false)
        XCTAssertFalse(stacks.segments.first { $0.key == "code reviews" }?.isCalendarBucket ?? true)
        XCTAssertTrue(WeeklyBucketing.isCalendarBucketKey(calHealth))
        XCTAssertFalse(WeeklyBucketing.isCalendarBucketKey("code reviews"))
    }

    func testNoWholeCalendarsMeansAllTasksIndividual() {
        let points = [
            tcPoint("2026-07-06", task: "walk", taskLabel: "Walk", cal: "health", hours: 2),
            tcPoint("2026-07-06", task: "reading", taskLabel: "Reading", cal: "health", hours: 1),
        ]
        let stacks = WeeklyBucketing.bucketByCalendarSegmentMode(
            points, calendar: mondayCalendar(), wholeCalendarKeys: [])
        XCTAssertEqual(stacks.segments.map(\.key), ["reading", "walk"])
        XCTAssertFalse(stacks.segments.contains { $0.isCalendarBucket })
    }

    func testWholeCalendarSegmentCarriesLabelAndColor() {
        let points = [
            tcPoint("2026-07-06", task: "richie", taskLabel: "Richie",
                    cal: "health", calLabel: "Health", color: "#123456", hours: 1),
        ]
        let stacks = WeeklyBucketing.bucketByCalendarSegmentMode(
            points, calendar: mondayCalendar(), wholeCalendarKeys: ["health"])
        let seg = stacks.segments.first
        XCTAssertEqual(seg?.label, "Health")
        XCTAssertEqual(seg?.colorHex, "#123456")
        XCTAssertTrue(seg?.isCalendarBucket ?? false)
    }

    func testZeroHourTasksExcluded() {
        let points = [
            tcPoint("2026-07-06", task: "walk", taskLabel: "Walk", cal: "health", hours: 0),
            tcPoint("2026-07-06", task: "reading", taskLabel: "Reading", cal: "health", hours: 1),
        ]
        let stacks = WeeklyBucketing.bucketByCalendarSegmentMode(
            points, calendar: mondayCalendar(), wholeCalendarKeys: [])
        XCTAssertEqual(stacks.segments.map(\.key), ["reading"])
    }

    func testTaskOrderingIsStableIgnoringHours() {
        // Alphabetical by task key regardless of hours, so the stacking order
        // stays stable week to week.
        let points = [
            tcPoint("2026-07-06", task: "walk", taskLabel: "Walk", cal: "health", hours: 10),
            tcPoint("2026-07-06", task: "apples", taskLabel: "Apples", cal: "health", hours: 1),
        ]
        let stacks = WeeklyBucketing.bucketByCalendarSegmentMode(
            points, calendar: mondayCalendar(), wholeCalendarKeys: [])
        XCTAssertEqual(stacks.segments.map(\.key), ["apples", "walk"])
    }
}

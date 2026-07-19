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
}

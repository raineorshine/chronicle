import XCTest
@testable import ChronicleCore

final class DetailSummaryTests: XCTestCase {

    private func segment(_ key: String, _ label: String, _ total: Double,
                         isOther: Bool = false) -> WeeklySegment {
        WeeklySegment(key: key, label: label, totalHours: total, isOther: isOther)
    }

    private func point(_ week: String, _ key: String, _ hours: Double) -> WeeklyStackPoint {
        WeeklyStackPoint(weekStart: week, segmentKey: key, segmentLabel: key, hours: hours)
    }

    // MARK: - Top by hours

    func testRanksSegmentsByWindowTotalAndCapsAtLimit() {
        let stacks = WeeklyStacks(points: [],
                                  segments: [segment("a", "A", 3), segment("b", "B", 10),
                                             segment("c", "C", 7), segment("d", "D", 1)],
                                  weekStarts: [])
        let top = DetailSummary.topByHours(stacks, limit: 3)

        XCTAssertEqual(top.map(\.segmentKey), ["b", "c", "a"])
        XCTAssertEqual(top.map(\.hours), [10, 7, 3])
    }

    func testTopByHoursBreaksTiesByLabelAndDropsEmptySegments() {
        let stacks = WeeklyStacks(points: [],
                                  segments: [segment("z", "Zebra", 5), segment("a", "Apple", 5),
                                             segment("e", "Empty", 0)],
                                  weekStarts: [])
        XCTAssertEqual(DetailSummary.topByHours(stacks).map(\.segmentKey), ["a", "z"])
    }

    func testTopByHoursExcludesTheOtherBucket() {
        let stacks = WeeklyStacks(points: [],
                                  segments: [segment(WeeklyBucketing.otherKey, "Other", 99,
                                                     isOther: true),
                                             segment("a", "A", 4)],
                                  weekStarts: [])
        XCTAssertEqual(DetailSummary.topByHours(stacks).map(\.segmentKey), ["a"])
    }

    // MARK: - Top movers

    func testRanksMoversByAbsoluteChangeInEitherDirection() {
        let stacks = WeeklyStacks(
            points: [point("2026-07-06", "up", 10), point("2026-07-13", "up", 12),
                     point("2026-07-06", "down", 9), point("2026-07-13", "down", 1),
                     point("2026-07-06", "small", 2), point("2026-07-13", "small", 5)],
            segments: [segment("up", "Up", 22), segment("down", "Down", 10),
                       segment("small", "Small", 7)],
            weekStarts: ["2026-07-06", "2026-07-13"])

        let movers = DetailSummary.topMovers(stacks,
                                             previousWeek: "2026-07-06",
                                             currentWeek: "2026-07-13")

        // -8, +3, +2 by magnitude.
        XCTAssertEqual(movers.map(\.segmentKey), ["down", "small", "up"])
        XCTAssertEqual(movers[0].delta, -8)
        XCTAssertEqual(movers[0].percentChange.map { ($0).rounded() }, -89)
    }

    func testMoverAppearingFromNothingHasNoPercentChange() {
        let stacks = WeeklyStacks(points: [point("2026-07-13", "news", 4)],
                                  segments: [segment("news", "News", 4)],
                                  weekStarts: ["2026-07-06", "2026-07-13"])

        let movers = DetailSummary.topMovers(stacks,
                                             previousWeek: "2026-07-06",
                                             currentWeek: "2026-07-13")

        XCTAssertEqual(movers.count, 1)
        XCTAssertEqual(movers[0].previousHours, 0)
        XCTAssertEqual(movers[0].currentHours, 4)
        XCTAssertNil(movers[0].percentChange)
    }

    func testSegmentsThatBarelyBudgedAreNotMovers() {
        let stacks = WeeklyStacks(
            points: [point("2026-07-06", "flat", 3), point("2026-07-13", "flat", 3.01),
                     point("2026-07-06", "same", 2), point("2026-07-13", "same", 2)],
            segments: [segment("flat", "Flat", 6), segment("same", "Same", 4)],
            weekStarts: ["2026-07-06", "2026-07-13"])

        XCTAssertTrue(DetailSummary.topMovers(stacks,
                                              previousWeek: "2026-07-06",
                                              currentWeek: "2026-07-13").isEmpty)
    }

    func testMoversIgnoreWeeksOutsideTheComparedPair() {
        let stacks = WeeklyStacks(
            points: [point("2026-06-29", "a", 40), point("2026-07-06", "a", 1),
                     point("2026-07-13", "a", 3)],
            segments: [segment("a", "A", 44)],
            weekStarts: ["2026-06-29", "2026-07-06", "2026-07-13"])

        let movers = DetailSummary.topMovers(stacks,
                                             previousWeek: "2026-07-06",
                                             currentWeek: "2026-07-13")

        XCTAssertEqual(movers.map(\.previousHours), [1])
        XCTAssertEqual(movers.map(\.currentHours), [3])
    }

    func testMoversExcludeTheOtherBucket() {
        let stacks = WeeklyStacks(
            points: [point("2026-07-06", WeeklyBucketing.otherKey, 1),
                     point("2026-07-13", WeeklyBucketing.otherKey, 20),
                     point("2026-07-13", "a", 2)],
            segments: [segment("a", "A", 2),
                       segment(WeeklyBucketing.otherKey, "Other", 21, isOther: true)],
            weekStarts: ["2026-07-06", "2026-07-13"])

        XCTAssertEqual(DetailSummary.topMovers(stacks,
                                               previousWeek: "2026-07-06",
                                               currentWeek: "2026-07-13").map(\.segmentKey),
                       ["a"])
    }

    func testMoversCapAtLimit() {
        let keys = ["a", "b", "c", "d", "e", "f"]
        let points = keys.enumerated().map { point("2026-07-13", $0.element, Double($0.offset + 1)) }
        let stacks = WeeklyStacks(points: points,
                                  segments: keys.map { segment($0, $0.uppercased(), 1) },
                                  weekStarts: ["2026-07-06", "2026-07-13"])

        let movers = DetailSummary.topMovers(stacks,
                                             previousWeek: "2026-07-06",
                                             currentWeek: "2026-07-13")

        XCTAssertEqual(movers.map(\.segmentKey), ["f", "e", "d", "c", "b"])
    }
}

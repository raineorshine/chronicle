import XCTest
@testable import ChronicleCore

final class ChartHitTestTests: XCTestCase {

    private func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")!
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }

    private func point(_ week: String, _ key: String, _ hours: Double) -> WeeklyStackPoint {
        WeeklyStackPoint(weekStart: week, segmentKey: key, segmentLabel: key, hours: hours)
    }

    private let weeks = ["2026-08-03", "2026-08-10", "2026-08-17"]
    private var weekDates: [Date] { weeks.map(date) }

    // MARK: - span

    func testSpanAtATickSitsAtFractionZero() {
        let span = ChartHitTest.span(at: date("2026-08-10"), in: weekDates)
        XCTAssertEqual(span, ChartHitTest.WeekSpan(left: 1, right: 2, fraction: 0))
    }

    func testSpanMidwayBetweenTicks() {
        let mid = date("2026-08-03").addingTimeInterval(3.5 * 86_400)
        let span = ChartHitTest.span(at: mid, in: weekDates)
        XCTAssertEqual(span?.left, 0)
        XCTAssertEqual(span?.right, 1)
        XCTAssertEqual(span?.fraction ?? 0, 0.5, accuracy: 1e-9)
    }

    func testSpanAtLastTickBracketsItselfSoNothingExtrapolates() {
        let span = ChartHitTest.span(at: date("2026-08-17"), in: weekDates)
        XCTAssertEqual(span, ChartHitTest.WeekSpan(left: 2, right: 2, fraction: 0))
    }

    /// The caller gates on the plot rectangle, so a date landing a hair outside
    /// the domain is an axis rounding artifact at the plot's edge, not a miss —
    /// clamping keeps the outermost pixel column hoverable.
    func testSpanClampsOutsideTheDomain() {
        XCTAssertEqual(ChartHitTest.span(at: date("2026-08-02"), in: weekDates),
                       ChartHitTest.WeekSpan(left: 0, right: 1, fraction: 0))
        XCTAssertEqual(ChartHitTest.span(at: date("2026-08-18"), in: weekDates),
                       ChartHitTest.WeekSpan(left: 2, right: 2, fraction: 0))
    }

    func testSpanWithNoTicksIsNil() {
        XCTAssertNil(ChartHitTest.span(at: date("2026-08-10"), in: []))
    }

    func testNearestTickFollowsTheHalfwayLine() {
        XCTAssertEqual(ChartHitTest.WeekSpan(left: 0, right: 1, fraction: 0.2).nearest, 0)
        XCTAssertEqual(ChartHitTest.WeekSpan(left: 0, right: 1, fraction: 0.9).nearest, 1)
    }

    // MARK: - segmentKey, at a week tick

    /// At a tick the two ends are the same week, so this is the plain stack walk:
    /// "a" occupies 0–4 hours, "b" 4–10.
    func testAtATickWalksThatWeeksStackBottomToTop() {
        let points = [point("2026-08-03", "a", 4), point("2026-08-03", "b", 6)]
        func hit(_ h: Double) -> String? {
            ChartHitTest.segmentKey(in: points, from: "2026-08-03", to: "2026-08-03",
                                    fraction: 0, hours: h)
        }
        XCTAssertEqual(hit(0), "a")
        XCTAssertEqual(hit(3.9), "a")
        XCTAssertEqual(hit(4.1), "b")
        XCTAssertEqual(hit(9.9), "b")
        XCTAssertNil(hit(10.1), "above the stack's top")
        XCTAssertNil(hit(-0.1), "below the baseline")
    }

    func testZeroHourSegmentsAreNeverHit() {
        let points = [point("2026-08-03", "a", 0), point("2026-08-03", "b", 6)]
        XCTAssertEqual(ChartHitTest.segmentKey(in: points, from: "2026-08-03", to: "2026-08-03",
                                               fraction: 0, hours: 0), "b")
    }

    // MARK: - segmentKey, between ticks

    /// The boundary between the two bands slopes from 2h to 6h across the gap, so
    /// halfway across it sits at 4h — not at either week's value.
    func testBetweenTicksTheBandBoundarySlopes() {
        let points = [point("2026-08-03", "a", 2), point("2026-08-03", "b", 8),
                      point("2026-08-10", "a", 6), point("2026-08-10", "b", 4)]
        func hit(_ h: Double) -> String? {
            ChartHitTest.segmentKey(in: points, from: "2026-08-03", to: "2026-08-10",
                                    fraction: 0.5, hours: h)
        }
        XCTAssertEqual(hit(3.9), "a")
        XCTAssertEqual(hit(4.1), "b")
        // A nearest-week hit test would have put the boundary at 2h (left week) or
        // 6h (right week); both misread this band.
        XCTAssertEqual(hit(2.5), "a")
        XCTAssertEqual(hit(5.5), "b")
    }

    func testTopOfTheStackSlopesToo() {
        let points = [point("2026-08-03", "a", 10), point("2026-08-10", "a", 0)]
        func hit(_ fraction: Double, _ h: Double) -> String? {
            ChartHitTest.segmentKey(in: points, from: "2026-08-03", to: "2026-08-10",
                                    fraction: fraction, hours: h)
        }
        XCTAssertEqual(hit(0.25, 7.4), "a")
        XCTAssertNil(hit(0.25, 7.6), "outside the tapering wedge")
        XCTAssertNil(hit(1, 0), "the band has collapsed to nothing")
    }

    /// A segment recorded in one week but not the other still draws a tapering
    /// wedge across the gap; a missing cell is a zero, not an absent band.
    func testSegmentMissingFromOneWeekTapersRatherThanVanishing() {
        let points = [point("2026-08-03", "a", 4), point("2026-08-10", "a", 4),
                      point("2026-08-10", "b", 8)]
        func hit(_ fraction: Double, _ h: Double) -> String? {
            ChartHitTest.segmentKey(in: points, from: "2026-08-03", to: "2026-08-10",
                                    fraction: fraction, hours: h)
        }
        XCTAssertEqual(hit(0.5, 5), "b", "half-height wedge reaches 4h to 8h")
        XCTAssertNil(hit(0.5, 8.1))
        XCTAssertNil(hit(0, 4.1), "nothing of b is drawn at the left tick")
    }

    /// Bands stack bottom→top in segment-key order, which is how the chart's
    /// series is built.
    func testStackingOrderFollowsSegmentKey() {
        let points = [point("2026-08-03", "zeta", 5), point("2026-08-03", "alpha", 5)]
        XCTAssertEqual(ChartHitTest.segmentKey(in: points, from: "2026-08-03", to: "2026-08-03",
                                               fraction: 0, hours: 1), "alpha")
        XCTAssertEqual(ChartHitTest.segmentKey(in: points, from: "2026-08-03", to: "2026-08-03",
                                               fraction: 0, hours: 6), "zeta")
    }

    func testEmptyWeekHasNothingToHit() {
        XCTAssertNil(ChartHitTest.segmentKey(in: [], from: "2026-08-03", to: "2026-08-10",
                                             fraction: 0.5, hours: 0))
    }

    // MARK: - hours

    func testHoursReadsACellAndTreatsAMissingOneAsZero() {
        let points = [point("2026-08-03", "a", 4)]
        XCTAssertEqual(ChartHitTest.hours(in: points, week: "2026-08-03", segmentKey: "a"), 4)
        XCTAssertEqual(ChartHitTest.hours(in: points, week: "2026-08-10", segmentKey: "a"), 0)
        XCTAssertEqual(ChartHitTest.hours(in: points, week: "2026-08-03", segmentKey: "b"), 0)
    }
}

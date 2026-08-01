import XCTest
@testable import ChronicleCore

final class ChartAxisTests: XCTestCase {

    /// Gregorian, UTC, Monday-start — deterministic week boundaries.
    private func mondayCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 2 // Monday
        return cal
    }

    private let locale = Locale(identifier: "en_US")

    private func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.calendar = mondayCalendar()
        f.timeZone = TimeZone(identifier: "UTC")!
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }

    func testWeekRangeLabelWithinOneMonth() {
        let label = ChartAxis.weekRangeLabel(weekStart: date("2026-07-06"),
                                             calendar: mondayCalendar(),
                                             locale: locale)
        XCTAssertEqual(label, "Jul 6–12")
    }

    func testWeekRangeLabelRepeatsMonthWhenWeekStraddlesMonths() {
        let label = ChartAxis.weekRangeLabel(weekStart: date("2026-06-29"),
                                             calendar: mondayCalendar(),
                                             locale: locale)
        XCTAssertEqual(label, "Jun 29–Jul 5")
    }

    func testWeekRangeLabelAcrossYearBoundary() {
        let label = ChartAxis.weekRangeLabel(weekStart: date("2025-12-29"),
                                             calendar: mondayCalendar(),
                                             locale: locale)
        XCTAssertEqual(label, "Dec 29–Jan 4")
    }

    func testMonthBoundariesExcludeDomainEndpoints() {
        // A 12-week window: Mondays 2026-05-18 through 2026-08-03.
        let domain = date("2026-05-18")...date("2026-08-03")
        let boundaries = ChartAxis.monthBoundaries(in: domain, calendar: mondayCalendar())
        XCTAssertEqual(boundaries, [date("2026-06-01"), date("2026-07-01"), date("2026-08-01")])
    }

    func testMonthBoundariesSkipsFirstOfMonthOnTheDomainEdge() {
        let domain = date("2026-06-01")...date("2026-07-20")
        let boundaries = ChartAxis.monthBoundaries(in: domain, calendar: mondayCalendar())
        XCTAssertEqual(boundaries, [date("2026-07-01")])
    }

    func testMonthLabelDatesStartAtEachMonthSpan() {
        // The window opens mid-May, so "May" is labeled at the domain edge and
        // the later months at their dividers.
        let domain = date("2026-05-18")...date("2026-08-01")
        let labels = ChartAxis.monthLabelDates(in: domain, calendar: mondayCalendar())
        XCTAssertEqual(labels, [date("2026-05-18"), date("2026-06-01"), date("2026-07-01")])
        XCTAssertEqual(labels.map {
            ChartAxis.monthLabel(for: $0, calendar: mondayCalendar(), locale: locale)
        }, ["May", "Jun", "Jul"])
    }

    func testMonthLabelDatesSkipSpansShorterThanMinimum() {
        // The window opens three days before August, too narrow to label "Jul".
        let domain = date("2026-07-29")...date("2026-09-14")
        let labels = ChartAxis.monthLabelDates(in: domain, calendar: mondayCalendar())
        let names = labels.map {
            ChartAxis.monthLabel(for: $0, calendar: mondayCalendar(), locale: locale)
        }
        XCTAssertEqual(names, ["Aug", "Sep"])
    }
}

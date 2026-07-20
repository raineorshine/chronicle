import XCTest
@testable import ChronicleCore

final class WeeklyMetricsTests: XCTestCase {

    /// Monday-first Gregorian calendar in a fixed zone, mirroring the app.
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2 // Monday
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ ymd: String) -> Date {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: ymd)!
    }

    private func ymd(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    // 2024-01-01 is a Monday; 2023-12-25 is the prior Monday.

    func testFridayCutoffUsesPreviousWeekMonThroughThu() {
        for day in ["2024-01-01", "2024-01-02", "2024-01-03", "2024-01-04"] {
            let start = WeeklyMetrics.weekStart(for: date(day), cutoffWeekday: 6, calendar: calendar)
            XCTAssertEqual(ymd(start), "2023-12-25", "expected previous week on \(day)")
        }
    }

    func testFridayCutoffUsesCurrentWeekFriThroughSun() {
        for day in ["2024-01-05", "2024-01-06", "2024-01-07"] {
            let start = WeeklyMetrics.weekStart(for: date(day), cutoffWeekday: 6, calendar: calendar)
            XCTAssertEqual(ymd(start), "2024-01-01", "expected current week on \(day)")
        }
    }

    func testPreviousWeekBoundsSpanFullMonToSun() {
        // Wednesday, before the Friday cutoff -> whole previous week.
        let bounds = WeeklyMetrics.bounds(for: date("2024-01-03"), cutoffWeekday: 6, calendar: calendar)
        XCTAssertEqual(ymd(bounds.from), "2023-12-25")
        XCTAssertEqual(ymd(bounds.to), "2023-12-31")
    }

    func testCurrentWeekBoundsAreCappedAtToday() {
        // Friday, on the cutoff -> current week capped at today, not Sunday.
        let bounds = WeeklyMetrics.bounds(for: date("2024-01-05"), cutoffWeekday: 6, calendar: calendar)
        XCTAssertEqual(ymd(bounds.from), "2024-01-01")
        XCTAssertEqual(ymd(bounds.to), "2024-01-05")
    }

    func testNonDefaultCutoffWednesday() {
        // Cutoff = Wednesday (Foundation weekday 4): Mon/Tue -> previous, Wed+ -> current.
        let tue = WeeklyMetrics.weekStart(for: date("2024-01-02"), cutoffWeekday: 4, calendar: calendar)
        XCTAssertEqual(ymd(tue), "2023-12-25")
        let wed = WeeklyMetrics.weekStart(for: date("2024-01-03"), cutoffWeekday: 4, calendar: calendar)
        XCTAssertEqual(ymd(wed), "2024-01-01")
    }

    func testTimeOfDayDoesNotAffectResult() {
        let lateFriday = date("2024-01-05").addingTimeInterval(23 * 3600 + 59 * 60)
        let start = WeeklyMetrics.weekStart(for: lateFriday, cutoffWeekday: 6, calendar: calendar)
        XCTAssertEqual(ymd(start), "2024-01-01")
    }
}

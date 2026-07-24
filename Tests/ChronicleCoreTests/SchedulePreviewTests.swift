import XCTest
@testable import ChronicleCore

final class SchedulePreviewTests: XCTestCase {

    /// Gregorian, UTC, Monday-start — deterministic week boundaries.
    private func mondayCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 2 // Monday
        return cal
    }

    /// Wednesday, 2026-07-15 at noon — mid-week and mid-month, so both preview
    /// shapes have room on either side of "now".
    private var now: Date { date(15, 12, 0) }

    /// A July 2026 date. 2026-07-13 is a Monday, so the 15th is a Wednesday.
    private func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 7
        parts.day = day
        parts.hour = hour
        parts.minute = minute
        return mondayCalendar().date(from: parts)!
    }

    private func occurrence(_ day: Int, _ hour: Int, _ minute: Int = 0,
                            _ frequency: ScheduleFrequency? = .weekly,
                            lasting durationMinutes: Int = 60) -> ScheduleOccurrence {
        let start = date(day, hour, minute)
        return ScheduleOccurrence(start: start,
                                  end: start.addingTimeInterval(TimeInterval(durationMinutes) * 60),
                                  frequency: frequency)
    }

    private func build(_ occurrences: [ScheduleOccurrence]) -> SchedulePreview? {
        SchedulePreviewBuilder.build(occurrences: occurrences,
                                     now: now,
                                     calendar: mondayCalendar())
    }

    /// The week preview's day columns, or a failure if it built something else.
    private func weekDays(_ occurrences: [ScheduleOccurrence],
                          file: StaticString = #filePath,
                          line: UInt = #line) -> [[ScheduleMark]] {
        guard case .week(let days)? = build(occurrences) else {
            XCTFail("expected a week preview", file: file, line: line)
            return []
        }
        return days
    }

    // MARK: - Week

    func testPlacesOccurrencesInTheirDayColumnAndTimeOfDay() {
        // Mon 9am, Wed 3pm — 9am is one hour into the 14-hour band, 3pm is halfway.
        let days = weekDays([occurrence(13, 9), occurrence(15, 15)])

        XCTAssertEqual(days.map(\.count), [1, 0, 1, 0, 0, 0, 0])
        XCTAssertEqual(days[0][0].fraction, 1.0 / 14.0, accuracy: 0.0001)
        XCTAssertEqual(days[2][0].fraction, 0.5, accuracy: 0.0001)
    }

    func testSundayIsTheLastColumn() {
        let days = weekDays([occurrence(19, 10)])
        XCTAssertEqual(days.map(\.count), [0, 0, 0, 0, 0, 0, 1])
    }

    /// Times outside 8am–10pm pin to an edge rather than vanishing, while the
    /// mark keeps the real time for labels.
    func testTimesOutsideTheBandClampToTheEdges() {
        let days = weekDays([occurrence(13, 6), occurrence(14, 23, 30)])

        XCTAssertEqual(days[0][0].fraction, 0)
        XCTAssertEqual(days[0][0].minutes, 6 * 60)
        XCTAssertEqual(days[1][0].fraction, 1)
        XCTAssertEqual(days[1][0].minutes, 23 * 60 + 30)
    }

    // MARK: - Duration

    /// A mark is as long as its event, measured against the 14-hour band.
    func testDurationIsProportionalToTheEventLength() {
        let days = weekDays([occurrence(13, 9, 0, .weekly, lasting: 60),
                             occurrence(14, 9, 0, .weekly, lasting: 150)])

        XCTAssertEqual(days[0][0].durationFraction, 1.0 / 14.0, accuracy: 0.0001)
        XCTAssertEqual(days[1][0].durationFraction, 2.5 / 14.0, accuracy: 0.0001)
    }

    /// Only the part of an event inside the band counts: a 7–9am event shows the
    /// hour from 8am on, pinned to the top.
    func testDurationCountsOnlyThePartInsideTheBand() {
        let days = weekDays([occurrence(13, 7, 0, .weekly, lasting: 120)])

        XCTAssertEqual(days[0][0].fraction, 0)
        XCTAssertEqual(days[0][0].durationFraction, 1.0 / 14.0, accuracy: 0.0001)
    }

    func testDurationIsTruncatedAtTheBottomOfTheBand() {
        // 9pm for two hours: only the hour to 10pm is inside the band.
        let days = weekDays([occurrence(13, 21, 0, .weekly, lasting: 120)])

        XCTAssertEqual(days[0][0].fraction, 13.0 / 14.0, accuracy: 0.0001)
        XCTAssertEqual(days[0][0].durationFraction, 1.0 / 14.0, accuracy: 0.0001)
    }

    /// An event running past midnight has no time-of-day end to compare against,
    /// so it runs to the bottom of the band instead of measuring negative.
    func testEventRunningPastMidnightRunsToTheBottom() {
        let days = weekDays([occurrence(13, 21, 0, .weekly, lasting: 240)])

        XCTAssertEqual(days[0][0].fraction, 13.0 / 14.0, accuracy: 0.0001)
        XCTAssertEqual(days[0][0].durationFraction, 1.0 / 14.0, accuracy: 0.0001)
    }

    func testZeroLengthEventHasNoDuration() {
        let days = weekDays([occurrence(13, 9, 0, .weekly, lasting: 0)])
        XCTAssertEqual(days[0][0].durationFraction, 0)
    }

    func testMultipleOccurrencesInADayAllShowSortedByTime() {
        let days = weekDays([occurrence(15, 17), occurrence(15, 9, 30)])

        XCTAssertEqual(days[2].map(\.minutes), [9 * 60 + 30, 17 * 60])
    }

    func testOccurrencesOutsideTheCurrentWeekAreIgnored() {
        // Next Monday is outside this Mon–Sun week, so only Wednesday's remains.
        let days = weekDays([occurrence(15, 9), occurrence(20, 9)])
        XCTAssertEqual(days.map(\.count), [0, 0, 1, 0, 0, 0, 0])
    }

    // MARK: - Frequency routing

    func testMonthlyOnlyTasksGetTheMonthGrid() {
        // July 2026 has 31 days and starts on a Wednesday (two leading blanks).
        guard case .month(let month)? = build([occurrence(3, 9, 0, .monthly)]) else {
            return XCTFail("expected a month preview")
        }
        XCTAssertEqual(month.leadingBlanks, 2)
        XCTAssertEqual(month.dayCount, 31)
        XCTAssertEqual(month.markedDays, [3])
        XCTAssertEqual(month.today, 15)
    }

    func testYearlyCountsAsMonthly() {
        guard case .month? = build([occurrence(3, 9, 0, .yearly)]) else {
            return XCTFail("expected a month preview")
        }
    }

    /// Mixed frequencies fall back to the week, which can render anything.
    func testMixedFrequenciesFallBackToTheWeek() {
        let days = weekDays([occurrence(15, 9, 0, .monthly), occurrence(16, 9, 0, .weekly)])
        XCTAssertEqual(days.map(\.count), [0, 0, 1, 1, 0, 0, 0])
    }

    func testDailyTasksUseTheWeek() {
        let days = weekDays([occurrence(15, 9, 0, .daily), occurrence(16, 9, 0, .daily)])
        XCTAssertEqual(days.map(\.count), [0, 0, 1, 1, 0, 0, 0])
    }

    /// The preview shows the shape of a routine, so a one-off event is dropped
    /// rather than drawn as if it were part of the pattern.
    func testOneOffEventsAreIgnored() {
        let days = weekDays([occurrence(15, 9, 0, .weekly), occurrence(16, 9, 0, nil)])
        XCTAssertEqual(days.map(\.count), [0, 0, 1, 0, 0, 0, 0])
    }

    func testOnlyOneOffEventsProducesNoPreview() {
        XCTAssertNil(build([occurrence(15, 9, 0, nil), occurrence(16, 14, 0, nil)]))
    }

    /// A one-off alongside a monthly series must not tip the task into the week
    /// preview: it is dropped before the weekly-vs-monthly choice is made.
    func testOneOffAlongsideMonthlyStillUsesTheMonth() {
        guard case .month(let month)? = build([occurrence(3, 9, 0, .monthly),
                                               occurrence(15, 9, 0, nil)]) else {
            return XCTFail("expected a month preview")
        }
        XCTAssertEqual(month.markedDays, [3])
    }

    // MARK: - Nothing to show

    func testNoOccurrencesProducesNoPreview() {
        XCTAssertNil(build([]))
    }

    func testWeekWithNoOccurrencesInRangeProducesNoPreview() {
        // A weekly series whose only fetched occurrence is in a later week.
        XCTAssertNil(build([occurrence(22, 9)]))
    }

    func testMonthlySeriesOutsideThisMonthProducesNoPreview() {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 8
        parts.day = 3
        parts.hour = 9
        let august = mondayCalendar().date(from: parts)!
        XCTAssertNil(build([ScheduleOccurrence(start: august,
                                               end: august.addingTimeInterval(3600),
                                               frequency: .monthly)]))
    }
}

/// The one piece of `ScheduleReader` that is pure enough to test without a live
/// EventKit store — and the piece that decides whether a moved occurrence of a
/// recurring series is recognized as recurring at all.
final class ScheduleReaderIdentifierTests: XCTestCase {

    func testStripsTheRecurrenceInstanceSuffix() {
        XCTAssertEqual(
            ScheduleReader.seriesIdentifier(from: "49FB9F41-6CA1-4E8E-BCF8-CB3BCC13A0D5/RID=806278500"),
            "49FB9F41-6CA1-4E8E-BCF8-CB3BCC13A0D5")
    }

    func testLeavesAnUndetachedIdentifierAlone() {
        XCTAssertEqual(
            ScheduleReader.seriesIdentifier(from: "1F8FBCF0-EA1E-4301-907E-5A9A1061BC2F"),
            "1F8FBCF0-EA1E-4301-907E-5A9A1061BC2F")
    }

    func testEmptyIdentifierIsUnchanged() {
        XCTAssertEqual(ScheduleReader.seriesIdentifier(from: ""), "")
    }
}

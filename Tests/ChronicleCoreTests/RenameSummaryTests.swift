import XCTest
@testable import ChronicleCore

/// A rename reuses `TaskReplacementPlanner` for matching — the rules are
/// identical — and differs only in how the ops are written: the query window
/// reaches into the past, and a recurring op retitles the whole series instead
/// of splitting it at today. These cover the breakdown the rename sheet states,
/// which counts calendar events rather than their occurrences.
final class RenameSummaryTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func day(_ offset: Int) -> Date {
        base.addingTimeInterval(TimeInterval(offset) * 86_400)
    }

    private func candidate(_ id: String,
                           title: String,
                           every frequency: ScheduleFrequency? = nil,
                           recurring: Bool? = nil,
                           editable: Bool = true,
                           start: Date? = nil) -> ReplacementCandidate {
        ReplacementCandidate(occurrenceID: id,
                             rawTitle: title,
                             isAllDay: false,
                             isRecurring: recurring ?? (frequency != nil),
                             allowsModification: editable,
                             occurrenceStart: start ?? base,
                             frequency: frequency)
    }

    private func summary(_ candidates: [ReplacementCandidate],
                         task: String = "email") -> RenameSummary {
        RenameSummary(plan: TaskReplacementPlanner.plan(candidates: candidates,
                                                        targetTaskKey: task),
                      candidates: candidates)
    }

    // MARK: - Counting

    /// Counts events, not occurrences: a series counts once however often it
    /// repeats, since one write retitles all of it.
    func testSeriesCountsOnceHoweverOftenItRepeats() {
        let result = summary([candidate("s", title: "Email", every: .weekly, start: day(-30)),
                              candidate("s", title: "Email", every: .weekly, start: day(1)),
                              candidate("s", title: "Email", every: .weekly, start: day(8))])

        XCTAssertEqual(result.renamed, [.weekly: 1])
        XCTAssertEqual(result.totalRenamed, 1)
        XCTAssertEqual(result.eventPhrase, "1 weekly event")
    }

    /// Distinct series sharing one title — e.g. a Mon, a Tue and a Wed weekly —
    /// are three separate calendar events, and must read as such.
    func testDistinctSeriesSharingATitleCountSeparately() {
        let result = summary([candidate("mon", title: "Email", every: .weekly, start: day(0)),
                              candidate("tue", title: "Email", every: .weekly, start: day(1)),
                              candidate("wed", title: "Email", every: .weekly, start: day(2))])

        XCTAssertEqual(result.renamed, [.weekly: 3])
        XCTAssertEqual(result.eventPhrase, "3 weekly events")
    }

    func testMixedCadencesAreCountedPerKind() {
        let result = summary([candidate("m", title: "Email", every: .monthly, start: day(0)),
                              candidate("one", title: "Email", start: day(3))])

        XCTAssertEqual(result.renamed, [.monthly: 1, .single: 1])
        XCTAssertEqual(result.eventPhrase, "1 monthly event and 1 single event")
    }

    func testStandaloneEventsReadAsSingle() {
        let result = summary([candidate("a", title: "Email", start: day(-400)),
                              candidate("b", title: "Email", start: day(-10)),
                              candidate("c", title: "Email", start: day(2)),
                              candidate("d", title: "Email", start: day(400))])

        XCTAssertEqual(result.renamed, [.single: 4])
        XCTAssertEqual(result.eventPhrase, "4 single events")
    }

    /// A series whose cadence has no plain name (every *n* periods, so
    /// `frequency` is nil) must not be mislabelled — it reads as repeating.
    func testUnnamedCadenceReadsAsRepeating() {
        let result = summary([candidate("s", title: "Email", recurring: true, start: day(0))])

        XCTAssertEqual(result.renamed, [.repeating: 1])
        XCTAssertEqual(result.eventPhrase, "1 repeating event")
    }

    func testReadOnlyMatchesAreCountedSeparately() {
        let result = summary([candidate("s", title: "Email", every: .daily, start: day(0)),
                              candidate("ro", title: "Email", editable: false, start: day(3))])

        XCTAssertEqual(result.renamed, [.daily: 1])
        XCTAssertEqual(result.skippedReadOnly, 1)
    }

    func testEmptyPlanRenamesNothing() {
        let result = summary([candidate("a", title: "Standup")])

        XCTAssertEqual(result, RenameSummary(renamed: [:], skippedReadOnly: 0))
        XCTAssertEqual(result.totalRenamed, 0)
        XCTAssertEqual(result.eventPhrase, "")
    }

    // MARK: - Phrasing

    /// Reads most frequent first, one-offs last, so the list is stable however
    /// the dictionary happens to be ordered.
    func testPhraseOrdersKindsFromMostFrequentToOneOff() {
        let phrase = RenameSummary(renamed: [.single: 2, .weekly: 1, .daily: 3],
                                   skippedReadOnly: 0).eventPhrase

        XCTAssertEqual(phrase, "3 daily events, 1 weekly event, and 2 single events")
    }

    func testPhrasePluralizesPerKind() {
        XCTAssertEqual(RenameSummary(renamed: [.yearly: 1], skippedReadOnly: 0).eventPhrase,
                       "1 yearly event")
        XCTAssertEqual(RenameSummary(renamed: [.yearly: 2], skippedReadOnly: 0).eventPhrase,
                       "2 yearly events")
    }

    /// Zero-count kinds are dropped rather than phrased as "0 …".
    func testZeroCountsAreOmitted() {
        let result = RenameSummary(renamed: [.weekly: 1, .single: 0], skippedReadOnly: 0)

        XCTAssertEqual(result.renamed, [.weekly: 1])
        XCTAssertEqual(result.eventPhrase, "1 weekly event")
    }
}

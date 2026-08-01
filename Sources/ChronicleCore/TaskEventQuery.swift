import Foundation
import EventKit

/// The EventKit read shared by Chronicle's calendar *write* paths — replacing a
/// task from today onward, and renaming one outright. Fetches the events in a
/// window and maps them to the `ReplacementCandidate`s the planner understands.
///
/// Only calendars Chronicle already tracks (allowlisted or subtractive) are
/// queried, matching `CalendarExtractor.extract`, so a write can never reach
/// events the dashboard doesn't count.
enum TaskEventQuery {

    /// Events overlapping `start..<end` on the tracked calendars, alongside the
    /// planner candidates derived from them. The two arrays share indices, so a
    /// plan's `candidateIndex` indexes into `events`.
    static func fetch(store: EKEventStore,
                      config: ChronicleConfig,
                      start: Date,
                      end: Date) -> (events: [EKEvent], candidates: [ReplacementCandidate]) {
        let included = CalendarSelection.included(from: store.calendars(for: .event),
                                                  config: config)
        guard !included.isEmpty else { return ([], []) }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: included)
        let events = store.events(matching: predicate)

        let candidates = events.enumerated().map { index, event in
            let identifier = event.eventIdentifier ?? ""
            return ReplacementCandidate(
                // Fall back to a per-row identity so events without an identifier
                // can never be collapsed into one another by the series dedupe.
                occurrenceID: identifier.isEmpty ? "index:\(index)" : identifier,
                rawTitle: event.title ?? "",
                isAllDay: event.isAllDay,
                isRecurring: event.hasRecurrenceRules,
                allowsModification: event.calendar.allowsContentModifications,
                occurrenceStart: event.startDate ?? .distantFuture,
                frequency: frequency(of: event))
        }
        return (events, candidates)
    }

    /// The plain-named cadence of the series `event` belongs to, or nil when it
    /// has none: a one-off, or a rule that repeats every *n* periods (an
    /// every-other-week series is not a "weekly" one).
    private static func frequency(of event: EKEvent) -> ScheduleFrequency? {
        guard let rule = event.recurrenceRules?.first, rule.interval <= 1 else { return nil }
        switch rule.frequency {
        case .daily: return .daily
        case .weekly: return .weekly
        case .monthly: return .monthly
        case .yearly: return .yearly
        @unknown default: return nil
        }
    }
}

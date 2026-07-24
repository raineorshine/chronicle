import Foundation
import EventKit

/// Reads a task's upcoming occurrences from EventKit for the schedule preview.
///
/// The read-only counterpart to `TaskReplacer`: same title matching, but it never
/// writes and never prompts. Without Calendar access the reads come back empty, so
/// a decorative preview can't put a permission dialog in front of the user.
///
/// Unlike the extractor and the replacer, this reads only the *planned*
/// calendars: an activity logged on a subtractive calendar as well as scheduled
/// on a normal one is one occurrence, not two.
public final class ScheduleReader {
    private let store: EKEventStore

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    /// Occurrences of `targetTaskKey` across the span covering both the current
    /// week and the current month, which is everything either preview shape can
    /// draw. Passing `targetSubtaskKey` narrows to that one subtask.
    ///
    /// Matching mirrors `TaskReplacementPlanner.plan`: only timed events count,
    /// and an event belongs to a task when its title *parses* to that task key, so
    /// `Email - Reply` matches the task `email` just like `Email`.
    public func occurrences(targetTaskKey: String,
                            targetSubtaskKey: String? = nil,
                            config: ChronicleConfig,
                            now: Date = Date(),
                            calendar: Calendar = .current) -> [ScheduleOccurrence] {
        // No authorization check: EventKit prompts only on an explicit request,
        // and reads without access simply return nothing. Checking the reported
        // status instead would be *stricter* than reality — after a rebuild it can
        // read `notDetermined` while a usable grant is still in place, which turned
        // a readable calendar into an empty preview with nothing to explain it.
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now),
              let month = calendar.dateInterval(of: .month, for: now) else { return [] }

        let planned = CalendarSelection.planned(from: store.calendars(for: .event), config: config)
        guard !planned.isEmpty else { return [] }

        let predicate = store.predicateForEvents(withStart: min(week.start, month.start),
                                                 end: max(week.end, month.end),
                                                 calendars: planned)

        // Series frequencies resolved for detached occurrences, so a series with
        // several edited instances costs one lookup rather than one per instance.
        var seriesFrequencies: [String: ScheduleFrequency] = [:]

        return store.events(matching: predicate).compactMap { event in
            // All-day events are never extracted, so they never form a task.
            guard !event.isAllDay, let start = event.startDate else { return nil }
            guard let parsed = TitleParser.parse(event.title ?? "",
                                                 separators: config.subtaskSeparators),
                  parsed.task.key == targetTaskKey else { return nil }
            if let targetSubtaskKey, parsed.subtask?.key != targetSubtaskKey { return nil }
            return ScheduleOccurrence(start: start,
                                      end: event.endDate ?? start,
                                      frequency: frequency(of: event, cache: &seriesFrequencies))
        }
    }

    /// The frequency of the series `event` belongs to, or nil for a true one-off.
    ///
    /// A *detached* occurrence — one instance of a series moved or edited on its
    /// own — carries no recurrence rules itself, so taking `event.recurrenceRules`
    /// at face value would report it as a one-off and drop it from the preview,
    /// leaving a hole on the day the user actually rescheduled it to. Those fall
    /// back to the series they came from, which shares their external identifier.
    private func frequency(of event: EKEvent,
                           cache: inout [String: ScheduleFrequency]) -> ScheduleFrequency? {
        if let rule = event.recurrenceRules?.first { return Self.frequency(of: rule) }
        guard event.isDetached, let external = event.calendarItemExternalIdentifier else {
            return nil
        }
        let seriesID = Self.seriesIdentifier(from: external)
        if let known = cache[seriesID] { return known }
        let found = store.calendarItems(withExternalIdentifier: seriesID)
            .compactMap { ($0 as? EKEvent)?.recurrenceRules?.first }
            .first
            .flatMap(Self.frequency(of:))
        if let found { cache[seriesID] = found }
        return found
    }

    /// The series' external identifier, given an occurrence's.
    ///
    /// A detached occurrence's identifier is the series' with a `/RID=<start>`
    /// suffix naming the instance it replaced, e.g.
    /// `49FB9F41-…-CB3BCC13A0D5/RID=806278500`. Looking that whole string up finds
    /// only the detached instance — which carries no recurrence rules — so the
    /// suffix has to come off to reach the series that does.
    static func seriesIdentifier(from externalIdentifier: String) -> String {
        guard let suffix = externalIdentifier.range(of: "/RID=") else {
            return externalIdentifier
        }
        return String(externalIdentifier[externalIdentifier.startIndex..<suffix.lowerBound])
    }

    /// A series with several rules is described by its first, which is what the
    /// preview's weekly-vs-monthly choice keys off.
    private static func frequency(of rule: EKRecurrenceRule) -> ScheduleFrequency? {
        switch rule.frequency {
        case .daily: return .daily
        case .weekly: return .weekly
        case .monthly: return .monthly
        case .yearly: return .yearly
        @unknown default: return nil
        }
    }
}

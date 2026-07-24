import Foundation
import EventKit

/// One upcoming calendar occurrence, decoupled from EventKit so the scanning
/// rule can be unit-tested without a live store.
public struct UpcomingOccurrence: Equatable {
    public let rawTitle: String
    public let isAllDay: Bool
    /// `EKEvent.hasRecurrenceRules`.
    public let isRecurring: Bool

    public init(rawTitle: String, isAllDay: Bool, isRecurring: Bool) {
        self.rawTitle = rawTitle
        self.isAllDay = isAllDay
        self.isRecurring = isRecurring
    }
}

/// One scope in the Task → Subtask hierarchy: a whole task when `subtaskKey` is
/// nil, or a single subtask under it otherwise. Mirrors how the sidebar keys its
/// rows, so a scope can be looked up from either level.
public struct TaskIdentity: Hashable {
    public let taskKey: String
    public let subtaskKey: String?

    public init(taskKey: String, subtaskKey: String? = nil) {
        self.taskKey = taskKey
        self.subtaskKey = subtaskKey
    }
}

/// Decides which tasks and subtasks still have a recurring series scheduled
/// ahead of them. Pure — no EventKit, no I/O — so the rule below is directly
/// testable.
///
/// Matching mirrors the extractor's semantics (`CalendarExtractor.extract`):
/// only timed events count, and an event belongs to the scope its title *parses*
/// to, so a recurring `Email - Reply` marks both the task `email` and its
/// subtask `reply` — the same pair of sidebar rows the event's hours land in.
public enum RecurringTaskScanner {

    /// Every task and subtask with at least one recurring occurrence among
    /// `occurrences`, which the caller is expected to have limited to the future.
    public static func identities(in occurrences: [UpcomingOccurrence],
                                  separators: [String] = [" - ", " | "]) -> Set<TaskIdentity> {
        var identities: Set<TaskIdentity> = []
        for occurrence in occurrences {
            // All-day events are never extracted, so they never form a task.
            guard occurrence.isRecurring, !occurrence.isAllDay else { continue }
            guard let parsed = TitleParser.parse(occurrence.rawTitle,
                                                 separators: separators) else { continue }
            identities.insert(TaskIdentity(taskKey: parsed.task.key))
            if let subtask = parsed.subtask {
                identities.insert(TaskIdentity(taskKey: parsed.task.key,
                                               subtaskKey: subtask.key))
            }
        }
        return identities
    }
}

/// Reads upcoming events from EventKit to find which tasks recur going forward,
/// for the sidebar's recurring marker.
public final class RecurringTaskReader {
    private let store: EKEventStore

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    /// How far ahead to look. Half a year catches daily through quarterly
    /// series while keeping the query small; a series whose next occurrence
    /// falls beyond it reads as non-recurring until it comes into range.
    public static let defaultHorizonDays = 180

    /// Every task and subtask with a recurring event scheduled from `now` onward.
    ///
    /// Only calendars Chronicle already tracks (allowlisted or subtractive) are
    /// considered, matching `CalendarExtractor.extract`, so the marker follows
    /// the same events the dashboard counts. Returns an empty set when full
    /// Calendar access is missing — this only drives a decoration, so it stays
    /// silent rather than throwing or prompting.
    public func futureRecurringIdentities(config: ChronicleConfig,
                                          horizonDays: Int = RecurringTaskReader.defaultHorizonDays,
                                          now: Date = Date(),
                                          calendar: Calendar = .current) -> Set<TaskIdentity> {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }

        let end = calendar.date(byAdding: .day, value: horizonDays, to: now) ?? now
        guard end > now else { return [] }

        let all = store.calendars(for: .event)
        let allow = Set(config.calendarAllowlist.map(Self.normalize))
        let subtractive = Set(config.subtractiveCalendars.map(Self.normalize))
        let included = all.filter {
            let key = Self.normalize($0.title)
            return allow.contains(key) || subtractive.contains(key)
        }
        guard !included.isEmpty else { return [] }

        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: included)
        let occurrences = store.events(matching: predicate).map {
            UpcomingOccurrence(rawTitle: $0.title ?? "",
                               isAllDay: $0.isAllDay,
                               isRecurring: $0.hasRecurrenceRules)
        }

        return RecurringTaskScanner.identities(in: occurrences,
                                               separators: config.subtaskSeparators)
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

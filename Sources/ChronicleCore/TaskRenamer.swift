import Foundation
import EventKit

/// What kind of event a rename touches. A calendar event is one thing whatever
/// its cadence, so the sheet counts events of each kind rather than occurrences:
/// three separate weekly series sharing a title are "3 weekly events", however
/// many times each of them repeats.
///
/// Declaration order is the order the breakdown reads in — most frequent first,
/// one-offs last.
public enum RenameEventKind: Int, Comparable, CaseIterable, Sendable {
    case daily
    case weekly
    case monthly
    case yearly
    /// A series with no plain-named cadence, e.g. one repeating every 3 weeks.
    case repeating
    /// A one-off event, belonging to no series.
    case single

    public static func < (lhs: RenameEventKind, rhs: RenameEventKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The kind of a *recurring* event with this cadence.
    init(frequency: ScheduleFrequency?) {
        switch frequency {
        case .daily: self = .daily
        case .weekly: self = .weekly
        case .monthly: self = .monthly
        case .yearly: self = .yearly
        case nil: self = .repeating
        }
    }

    /// How this kind names one event, e.g. "weekly event" / "single event".
    var noun: String {
        switch self {
        case .daily: return "daily event"
        case .weekly: return "weekly event"
        case .monthly: return "monthly event"
        case .yearly: return "yearly event"
        case .repeating: return "repeating event"
        case .single: return "single event"
        }
    }
}

/// What a rename does, for user-facing feedback. Used both as a prediction —
/// `TaskRenamer.preview` builds one before any write — and as the outcome
/// `TaskRenamer.rename` reports afterwards. Every count is per event, so a
/// recurring series counts once rather than once per occurrence.
public struct RenameSummary: Equatable, Sendable {
    /// How many events of each kind get the new title. Kinds with no events are
    /// absent rather than zero, so the breakdown reads only what applies.
    public let renamed: [RenameEventKind: Int]
    /// Matching events skipped because their calendar forbids edits.
    public let skippedReadOnly: Int

    public init(renamed: [RenameEventKind: Int], skippedReadOnly: Int) {
        self.renamed = renamed.filter { $0.value > 0 }
        self.skippedReadOnly = skippedReadOnly
    }

    /// The effect `plan` would have if every write succeeded. `candidates` is
    /// the array the plan was built from, which carries each event's cadence.
    public init(plan: ReplacementPlan, candidates: [ReplacementCandidate]) {
        var renamed: [RenameEventKind: Int] = [:]
        for op in plan.ops {
            let candidate = candidates.indices.contains(op.candidateIndex)
                ? candidates[op.candidateIndex] : nil
            let kind: RenameEventKind
            switch op.span {
            case .futureEvents: kind = RenameEventKind(frequency: candidate?.frequency)
            case .thisEvent: kind = .single
            }
            renamed[kind, default: 0] += 1
        }
        self.init(renamed: renamed, skippedReadOnly: plan.skippedReadOnly)
    }

    public var totalRenamed: Int { renamed.values.reduce(0, +) }

    /// The breakdown the rename sheet states, counting events rather than their
    /// occurrences — "1 monthly event and 1 single event", "3 weekly events".
    /// Empty when nothing matches.
    public var eventPhrase: String {
        let parts = renamed.keys.sorted().map { kind -> String in
            let count = renamed[kind] ?? 0
            return count == 1 ? "1 \(kind.noun)" : "\(count) \(kind.noun)s"
        }
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        case 2: return parts[0] + " and " + parts[1]
        default:
            return parts.dropLast().joined(separator: ", ") + ", and " + parts[parts.count - 1]
        }
    }
}

public enum RenameError: Error, CustomStringConvertible {
    case accessDenied
    case emptyTitle

    public var description: String {
        switch self {
        case .accessDenied:
            return "Full Calendar access is required to rename a task. Grant it in "
                + "System Settings › Privacy & Security › Calendars."
        case .emptyTitle:
            return "The new title cannot be empty."
        }
    }
}

/// Renames a task outright: every event that carries the title gets the new one,
/// past and future alike, and a recurring event is retitled across its whole
/// series rather than split in two.
///
/// This is deliberately blunter than both of Chronicle's other rename-shaped
/// tools:
///
/// - An **alias** (`AliasResolver`) doesn't touch the calendar at all; it
///   canonicalizes two titles into one activity at read time, which is what you
///   want when the *old* events should keep their old name.
/// - A **replace** (`TaskReplacer`) rewrites only from today onward and splits a
///   recurring series at today, so history stays under the former name.
/// - A **rename** leaves nothing behind under the old name, so no alias is
///   needed afterwards to keep the activity's history in one piece.
///
/// Matching mirrors the extractor's semantics, via `TaskReplacementPlanner`:
/// only timed events count, and an event belongs to a task when its title
/// *parses* to that task key, so `Email - Reply` matches the task `email`.
public final class TaskRenamer {
    private let store: EKEventStore

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    /// How far back and forward the event query reaches. A recurring series is
    /// renamed in full however old it is — the write targets the series itself,
    /// not the occurrence that was found — so these bounds only limit which
    /// *one-off* events are swept in.
    public static let defaultPastHorizonDays = 730
    public static let defaultFutureHorizonDays = 730

    /// Retitles every event mapping to `targetTaskKey`, in the past as well as
    /// the future. Passing a `targetSubtaskKey` narrows the change to that one
    /// subtask, leaving the task's other subtasks alone.
    ///
    /// Only calendars Chronicle already tracks (allowlisted or subtractive) are
    /// considered, matching `CalendarExtractor.extract`, so this never edits
    /// events the dashboard doesn't count.
    @discardableResult
    public func rename(targetTaskKey: String,
                       targetSubtaskKey: String? = nil,
                       newTitle: String,
                       config: ChronicleConfig,
                       pastHorizonDays: Int = TaskRenamer.defaultPastHorizonDays,
                       futureHorizonDays: Int = TaskRenamer.defaultFutureHorizonDays,
                       now: Date = Date(),
                       calendar: Calendar = .current) throws -> RenameSummary {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw RenameError.emptyTitle }

        let (events, candidates, plan) = try planWrites(targetTaskKey: targetTaskKey,
                                                       targetSubtaskKey: targetSubtaskKey,
                                                       config: config,
                                                       pastHorizonDays: pastHorizonDays,
                                                       futureHorizonDays: futureHorizonDays,
                                                       now: now,
                                                       calendar: calendar)
        guard !plan.ops.isEmpty else {
            return RenameSummary(renamed: [:], skippedReadOnly: plan.skippedReadOnly)
        }

        var renamed: [RenameEventKind: Int] = [:]
        do {
            for op in plan.ops {
                switch op.span {
                case .futureEvents:
                    // The planner picks the earliest occurrence *in the window*,
                    // which would leave anything before it under the old title.
                    // `event(withIdentifier:)` returns the series' very first
                    // occurrence, so `.futureEvents` from there covers the lot.
                    let event = store.event(withIdentifier: op.occurrenceID)
                        ?? events[op.candidateIndex]
                    event.title = title
                    try store.save(event, span: .futureEvents, commit: false)
                    let kind = RenameEventKind(frequency: candidates[op.candidateIndex].frequency)
                    renamed[kind, default: 0] += 1
                case .thisEvent:
                    let event = events[op.candidateIndex]
                    event.title = title
                    try store.save(event, span: .thisEvent, commit: false)
                    renamed[.single, default: 0] += 1
                }
            }
            try store.commit()
        } catch {
            // Drop the uncommitted in-memory edits so a partial batch can't leak
            // into later reads from this store.
            store.reset()
            throw error
        }

        return RenameSummary(renamed: renamed, skippedReadOnly: plan.skippedReadOnly)
    }

    /// What `rename` would do for this scope, without touching the calendar.
    /// Lets the UI state the blast radius — in events, not occurrences — before
    /// the user commits to a change that cannot be undone.
    public func preview(targetTaskKey: String,
                        targetSubtaskKey: String? = nil,
                        config: ChronicleConfig,
                        pastHorizonDays: Int = TaskRenamer.defaultPastHorizonDays,
                        futureHorizonDays: Int = TaskRenamer.defaultFutureHorizonDays,
                        now: Date = Date(),
                        calendar: Calendar = .current) throws -> RenameSummary {
        let (_, candidates, plan) = try planWrites(targetTaskKey: targetTaskKey,
                                                   targetSubtaskKey: targetSubtaskKey,
                                                   config: config,
                                                   pastHorizonDays: pastHorizonDays,
                                                   futureHorizonDays: futureHorizonDays,
                                                   now: now,
                                                   calendar: calendar)
        return RenameSummary(plan: plan, candidates: candidates)
    }

    /// Queries the tracked calendars across the whole horizon and plans the
    /// writes for `targetTaskKey`. Returns the queried events and their
    /// candidates alongside the plan, whose `candidateIndex` indexes into both.
    private func planWrites(targetTaskKey: String,
                            targetSubtaskKey: String?,
                            config: ChronicleConfig,
                            pastHorizonDays: Int,
                            futureHorizonDays: Int,
                            now: Date,
                            calendar: Calendar) throws -> (events: [EKEvent],
                                                           candidates: [ReplacementCandidate],
                                                           plan: ReplacementPlan) {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw RenameError.accessDenied
        }

        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -pastHorizonDays, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: futureHorizonDays, to: today) ?? today

        let (events, candidates) = TaskEventQuery.fetch(store: store,
                                                        config: config,
                                                        start: start,
                                                        end: end)

        let plan = TaskReplacementPlanner.plan(candidates: candidates,
                                               targetTaskKey: targetTaskKey,
                                               targetSubtaskKey: targetSubtaskKey,
                                               separators: config.subtaskSeparators)
        return (events, candidates, plan)
    }
}

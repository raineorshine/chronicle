import Foundation
import EventKit

/// One calendar-event occurrence considered for replacement, decoupled from
/// EventKit so the planning rules can be unit-tested without a live store.
public struct ReplacementCandidate: Equatable {
    /// `EKEvent.eventIdentifier`. Every occurrence of a recurring series shares
    /// this value, which is what lets the planner collapse a series to one write.
    public let occurrenceID: String
    public let rawTitle: String
    public let isAllDay: Bool
    /// `EKEvent.hasRecurrenceRules`.
    public let isRecurring: Bool
    /// `EKEvent.calendar.allowsContentModifications`.
    public let allowsModification: Bool
    public let occurrenceStart: Date

    public init(occurrenceID: String,
                rawTitle: String,
                isAllDay: Bool,
                isRecurring: Bool,
                allowsModification: Bool,
                occurrenceStart: Date) {
        self.occurrenceID = occurrenceID
        self.rawTitle = rawTitle
        self.isAllDay = isAllDay
        self.isRecurring = isRecurring
        self.allowsModification = allowsModification
        self.occurrenceStart = occurrenceStart
    }
}

/// How far a single write reaches. Mirrors `EKSpan`.
public enum ReplacementSpan: Equatable {
    /// A one-off event: only this event changes.
    case thisEvent
    /// A recurring series: this occurrence and every later one change, while
    /// past occurrences keep their old title.
    case futureEvents
}

/// A single planned write: which candidate to rewrite, and how far it reaches.
public struct ReplacementOp: Equatable {
    /// Index into the `candidates` array handed to the planner, so the caller can
    /// map back to the originating `EKEvent`.
    public let candidateIndex: Int
    public let occurrenceID: String
    public let span: ReplacementSpan

    public init(candidateIndex: Int, occurrenceID: String, span: ReplacementSpan) {
        self.candidateIndex = candidateIndex
        self.occurrenceID = occurrenceID
        self.span = span
    }
}

/// The full set of writes needed to replace one task, plus what was passed over.
public struct ReplacementPlan: Equatable {
    /// Ordered by `candidateIndex` so the plan is deterministic.
    public let ops: [ReplacementOp]
    /// Matching events on calendars that forbid edits (e.g. subscribed holiday
    /// calendars). Surfaced so the UI can explain why some events were untouched.
    public let skippedReadOnly: Int

    public init(ops: [ReplacementOp], skippedReadOnly: Int) {
        self.ops = ops
        self.skippedReadOnly = skippedReadOnly
    }
}

/// Decides which events a task replacement should rewrite. Pure — no EventKit,
/// no I/O — so every rule below is directly testable.
///
/// Matching mirrors the extractor's semantics (`CalendarExtractor.extract`): only
/// timed events count, and an event belongs to a task when its title *parses* to
/// that task key, so `Email - Reply` matches the task `email` just like `Email`.
public enum TaskReplacementPlanner {

    /// Builds the write plan for replacing `targetTaskKey`, optionally narrowed
    /// to a single subtask.
    ///
    /// A nil `targetSubtaskKey` means the whole task: every event under it
    /// matches, including ones carrying a subtask (`Email - Reply` matches the
    /// task `email`). A non-nil value narrows to events with exactly that
    /// subtask, so replacing `Email - Reply` leaves `Email - Triage` alone.
    ///
    /// Candidates are expected to already be limited to occurrences at/after the
    /// cutoff (the caller queries from the start of today), so "from today
    /// onward" falls out of the query bound plus `.futureEvents` below.
    ///
    /// - Recurring occurrences collapse to a single `.futureEvents` write on the
    ///   earliest occurrence, which splits the series at that point: past
    ///   occurrences keep the old title, this one and all later ones get the new.
    /// - Standalone events each get their own `.thisEvent` write.
    public static func plan(candidates: [ReplacementCandidate],
                            targetTaskKey: String,
                            targetSubtaskKey: String? = nil,
                            separators: [String] = [" - ", " | "]) -> ReplacementPlan {
        var ops: [ReplacementOp] = []
        var skippedReadOnly = 0
        // Earliest matching occurrence per recurring series, keyed by identifier.
        var earliestBySeries: [String: (index: Int, start: Date)] = [:]

        for (index, candidate) in candidates.enumerated() {
            // All-day events are never extracted, so they never form a task.
            if candidate.isAllDay { continue }
            guard let parsed = TitleParser.parse(candidate.rawTitle, separators: separators),
                  parsed.task.key == targetTaskKey else { continue }
            if let targetSubtaskKey, parsed.subtask?.key != targetSubtaskKey { continue }
            guard candidate.allowsModification else {
                skippedReadOnly += 1
                continue
            }

            if candidate.isRecurring {
                let existing = earliestBySeries[candidate.occurrenceID]
                if existing == nil || candidate.occurrenceStart < existing!.start {
                    earliestBySeries[candidate.occurrenceID] = (index, candidate.occurrenceStart)
                }
            } else {
                ops.append(ReplacementOp(candidateIndex: index,
                                         occurrenceID: candidate.occurrenceID,
                                         span: .thisEvent))
            }
        }

        for (occurrenceID, pick) in earliestBySeries {
            ops.append(ReplacementOp(candidateIndex: pick.index,
                                     occurrenceID: occurrenceID,
                                     span: .futureEvents))
        }

        ops.sort { $0.candidateIndex < $1.candidateIndex }
        return ReplacementPlan(ops: ops, skippedReadOnly: skippedReadOnly)
    }
}

/// What a replacement actually did, for user-facing feedback.
public struct ReplacementSummary: Equatable {
    /// Recurring series split at today and given the new title.
    public let replacedSeries: Int
    /// One-off events given the new title.
    public let replacedStandalone: Int
    /// Matching events skipped because their calendar forbids edits.
    public let skippedReadOnly: Int

    public init(replacedSeries: Int, replacedStandalone: Int, skippedReadOnly: Int) {
        self.replacedSeries = replacedSeries
        self.replacedStandalone = replacedStandalone
        self.skippedReadOnly = skippedReadOnly
    }

    public var totalReplaced: Int { replacedSeries + replacedStandalone }
}

public enum ReplacementError: Error, CustomStringConvertible {
    case accessDenied
    case emptyTitle

    public var description: String {
        switch self {
        case .accessDenied:
            return "Full Calendar access is required to replace a task. Grant it in "
                + "System Settings › Privacy & Security › Calendars."
        case .emptyTitle:
            return "The replacement title cannot be empty."
        }
    }
}

/// Writes task replacements back to the user's calendars through EventKit.
///
/// This is the app's only calendar *write* path. Changes land in the local
/// Calendar store and macOS syncs them onward to iCloud/CalDAV, so no CalDAV
/// client or credentials are needed here.
public final class TaskReplacer {
    private let store: EKEventStore

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    /// Default horizon for the forward query. `.futureEvents` covers a recurring
    /// series' entire future once any one occurrence is found, so two years is
    /// ample for series; standalone events scheduled beyond it are not reached.
    public static let defaultFutureHorizonDays = 730

    /// Replaces the title of every future event mapping to `targetTaskKey`, from
    /// the start of today onward. Past events are left untouched. Passing a
    /// `targetSubtaskKey` narrows the change to that one subtask.
    ///
    /// Only calendars Chronicle already tracks (allowlisted or subtractive) are
    /// considered, matching `CalendarExtractor.extract`, so this never edits
    /// events the dashboard doesn't count.
    @discardableResult
    public func replace(targetTaskKey: String,
                        targetSubtaskKey: String? = nil,
                        newTitle: String,
                        config: ChronicleConfig,
                        futureHorizonDays: Int = TaskReplacer.defaultFutureHorizonDays,
                        now: Date = Date(),
                        calendar: Calendar = .current) throws -> ReplacementSummary {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ReplacementError.emptyTitle }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw ReplacementError.accessDenied
        }

        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: futureHorizonDays, to: start) ?? start

        let all = store.calendars(for: .event)
        let allow = Set(config.calendarAllowlist.map(Self.normalize))
        let subtractive = Set(config.subtractiveCalendars.map(Self.normalize))
        let included = all.filter {
            let key = Self.normalize($0.title)
            return allow.contains(key) || subtractive.contains(key)
        }
        guard !included.isEmpty else {
            return ReplacementSummary(replacedSeries: 0, replacedStandalone: 0, skippedReadOnly: 0)
        }

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
                occurrenceStart: event.startDate ?? .distantFuture)
        }

        let plan = TaskReplacementPlanner.plan(candidates: candidates,
                                               targetTaskKey: targetTaskKey,
                                               targetSubtaskKey: targetSubtaskKey,
                                               separators: config.subtaskSeparators)
        guard !plan.ops.isEmpty else {
            return ReplacementSummary(replacedSeries: 0,
                                      replacedStandalone: 0,
                                      skippedReadOnly: plan.skippedReadOnly)
        }

        var replacedSeries = 0
        var replacedStandalone = 0
        do {
            for op in plan.ops {
                let event = events[op.candidateIndex]
                event.title = title
                switch op.span {
                case .futureEvents:
                    try store.save(event, span: .futureEvents, commit: false)
                    replacedSeries += 1
                case .thisEvent:
                    try store.save(event, span: .thisEvent, commit: false)
                    replacedStandalone += 1
                }
            }
            try store.commit()
        } catch {
            // Drop the uncommitted in-memory edits so a partial batch can't leak
            // into later reads from this store.
            store.reset()
            throw error
        }

        return ReplacementSummary(replacedSeries: replacedSeries,
                                  replacedStandalone: replacedStandalone,
                                  skippedReadOnly: plan.skippedReadOnly)
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

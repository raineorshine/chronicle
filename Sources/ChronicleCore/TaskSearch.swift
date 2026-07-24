import Foundation

/// One autosuggest hit: either an activity or one of its subtasks.
public struct TaskSearchResult: Identifiable, Equatable {
    public let taskKey: String
    public let taskLabel: String
    public let subtaskKey: String?
    public let subtaskLabel: String?
    public let hours: Double

    public init(taskKey: String,
                taskLabel: String,
                subtaskKey: String?,
                subtaskLabel: String?,
                hours: Double) {
        self.taskKey = taskKey
        self.taskLabel = taskLabel
        self.subtaskKey = subtaskKey
        self.subtaskLabel = subtaskLabel
        self.hours = hours
    }

    /// Mirrors the sidebar's node IDs (`task:<key>` / `sub:<task>:<sub>`) so a hit
    /// selects exactly the row a click in the sidebar would.
    public var id: String {
        guard let subtaskKey else { return "task:\(taskKey)" }
        return "sub:\(taskKey):\(subtaskKey)"
    }

    /// `Task` for an activity, `Task / Subtask` for a subtask.
    public var displayLabel: String {
        guard let subtaskLabel else { return taskLabel }
        return "\(taskLabel) / \(subtaskLabel)"
    }
}

/// Ranked substring search over the sidebar's activities and their subtasks.
/// Pure and case/diacritic-insensitive, so it can be driven straight from the
/// already-loaded `taskSummaries` without touching the database.
public enum TaskSearch {

    /// Match quality, best first. Ordering these as raw values lets the sort
    /// compare them directly.
    private enum Rank: Int {
        /// The candidate starts with the query.
        case prefix = 0
        /// The query starts one of the candidate's words.
        case wordBoundary = 1
        /// The query appears somewhere inside the candidate.
        case substring = 2
    }

    /// Best `limit` hits for `query`, ranked by match quality then by hours.
    /// A blank query matches nothing (the caller shows a hint instead).
    ///
    /// Subtasks are matched against `"<task label> <subtask label>"`, so a query
    /// spanning both levels (`"em review"`) finds `em / Code Reviews`.
    public static func match(_ query: String,
                             in tasks: [TaskSummary],
                             limit: Int = 8) -> [TaskSearchResult] {
        let needle = fold(query)
        guard !needle.isEmpty else { return [] }

        // (result, rank, isSubtask) — the tuple carries the sort keys that the
        // result itself doesn't.
        var hits: [(result: TaskSearchResult, rank: Rank, isSubtask: Bool)] = []

        for task in tasks {
            if let rank = rank(of: needle, in: task.label) {
                hits.append((TaskSearchResult(taskKey: task.key,
                                              taskLabel: task.label,
                                              subtaskKey: nil,
                                              subtaskLabel: nil,
                                              hours: task.hours),
                             rank, false))
            }
            for sub in task.subtasks {
                guard let rank = rank(of: needle, in: "\(task.label) \(sub.label)") else { continue }
                hits.append((TaskSearchResult(taskKey: task.key,
                                              taskLabel: task.label,
                                              subtaskKey: sub.key,
                                              subtaskLabel: sub.label,
                                              hours: sub.hours),
                             rank, true))
            }
        }

        hits.sort { a, b in
            if a.rank != b.rank { return a.rank.rawValue < b.rank.rawValue }
            if a.isSubtask != b.isSubtask { return !a.isSubtask }
            if a.result.hours != b.result.hours { return a.result.hours > b.result.hours }
            return a.result.displayLabel.localizedCaseInsensitiveCompare(b.result.displayLabel)
                == .orderedAscending
        }

        return hits.prefix(limit).map(\.result)
    }

    /// The first `limit` activities, in the order the sidebar lists them (by the
    /// metrics week's hours). Backs the suggestions shown before anything is
    /// typed, so an empty search box still offers somewhere to go.
    public static func topActivities(in tasks: [TaskSummary],
                                     limit: Int = 8) -> [TaskSearchResult] {
        tasks.prefix(limit).map {
            TaskSearchResult(taskKey: $0.key,
                             taskLabel: $0.label,
                             subtaskKey: nil,
                             subtaskLabel: nil,
                             hours: $0.hours)
        }
    }

    /// How well `needle` (already folded) matches `candidate`, or nil for no match.
    private static func rank(of needle: String, in candidate: String) -> Rank? {
        let hay = fold(candidate)
        guard let found = hay.range(of: needle) else { return nil }
        if found.lowerBound == hay.startIndex { return .prefix }
        let before = hay[hay.index(before: found.lowerBound)]
        return before.isLetter || before.isNumber ? .substring : .wordBoundary
    }

    /// Case- and diacritic-insensitive form used on both sides of the comparison.
    private static func fold(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

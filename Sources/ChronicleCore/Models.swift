import Foundation

/// A normalized name: a canonical display `label` (original casing preserved)
/// paired with a case-insensitive `key` used for grouping and comparison.
public struct NormalizedName: Equatable, Hashable {
    public let label: String
    public let key: String

    public init(label: String, key: String) {
        self.label = label
        self.key = key
    }

    /// True when normalization produced no usable content.
    public var isEmpty: Bool { key.isEmpty }
}

/// A parsed event title: a required Task and an optional Subtask.
public struct ParsedTitle: Equatable {
    public let task: NormalizedName
    public let subtask: NormalizedName?

    public init(task: NormalizedName, subtask: NormalizedName?) {
        self.task = task
        self.subtask = subtask
    }
}

/// A single event ready for aggregation, decoupled from EventKit for testing.
public struct EventInput {
    public let calendar: NormalizedName
    public let title: ParsedTitle
    public let start: Date
    public let end: Date
    public let isAllDay: Bool

    public init(calendar: NormalizedName,
                title: ParsedTitle,
                start: Date,
                end: Date,
                isAllDay: Bool) {
        self.calendar = calendar
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
    }
}

/// One row of the `daily_time` table: a single local day and hierarchy path.
public struct DailyRow: Equatable {
    public let date: String
    public let calendarKey: String
    public let calendarLabel: String
    public let taskKey: String
    public let taskLabel: String
    public let subtaskKey: String?
    public let subtaskLabel: String?
    public var durationSeconds: Int
    public var occurrenceCount: Int

    public init(date: String,
                calendarKey: String,
                calendarLabel: String,
                taskKey: String,
                taskLabel: String,
                subtaskKey: String?,
                subtaskLabel: String?,
                durationSeconds: Int,
                occurrenceCount: Int) {
        self.date = date
        self.calendarKey = calendarKey
        self.calendarLabel = calendarLabel
        self.taskKey = taskKey
        self.taskLabel = taskLabel
        self.subtaskKey = subtaskKey
        self.subtaskLabel = subtaskLabel
        self.durationSeconds = durationSeconds
        self.occurrenceCount = occurrenceCount
    }
}

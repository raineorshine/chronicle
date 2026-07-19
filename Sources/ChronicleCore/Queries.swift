import Foundation
import SQLite3

/// A hierarchy filter. `nil` at a level means "all descendants" (rollup).
public struct HierarchySelection: Equatable {
    public var calendarKey: String?
    public var taskKey: String?
    public var subtaskKey: String?

    public init(calendarKey: String? = nil,
                taskKey: String? = nil,
                subtaskKey: String? = nil) {
        self.calendarKey = calendarKey
        self.taskKey = taskKey
        self.subtaskKey = subtaskKey
    }

    public static let all = HierarchySelection()
}

/// One day of the plotted series.
public struct DailyPoint: Equatable {
    public let date: String
    public let hours: Double
    public let occurrences: Int

    public init(date: String, hours: Double, occurrences: Int) {
        self.date = date
        self.hours = hours
        self.occurrences = occurrences
    }
}

/// The dimension used to segment the weeks-on-X stacked chart. `task` segments
/// each bar by activity; `subtask` breaks a single activity into its subtasks.
public enum SegmentDimension: String, Equatable {
    case task
    case subtask
}

/// One day's contribution from a single chart segment (an activity or a
/// subtask), used to build the weekly stacked chart. `segmentKey` is a stable
/// identity **within the current scope**; `segmentLabel` is its display name.
public struct SegmentDailyPoint: Equatable {
    /// Sentinel `segmentKey` for the "(no subtask)" bucket.
    public static let noSubtaskKey = "\u{1F}nosub"

    public let date: String
    public let segmentKey: String
    public let segmentLabel: String
    public let hours: Double

    public init(date: String, segmentKey: String, segmentLabel: String, hours: Double) {
        self.date = date
        self.segmentKey = segmentKey
        self.segmentLabel = segmentLabel
        self.hours = hours
    }
}

/// One day of one calendar's contribution, for the stacked, colored chart.
public struct CalendarDailyPoint: Equatable, Identifiable {
    public let date: String
    public let calendarKey: String
    public let calendarLabel: String
    public let colorHex: String?
    public let hours: Double

    public var id: String { "\(date)|\(calendarKey)" }

    public init(date: String,
                calendarKey: String,
                calendarLabel: String,
                colorHex: String?,
                hours: Double) {
        self.date = date
        self.calendarKey = calendarKey
        self.calendarLabel = calendarLabel
        self.colorHex = colorHex
        self.hours = hours
    }
}

/// Totals for a selected range.
public struct RangeTotals: Equatable {
    public let totalHours: Double
    public let occurrences: Int

    public static let zero = RangeTotals(totalHours: 0, occurrences: 0)
}

// MARK: - Flat task list (for the selector)

/// A subtask's total hours over a window, merged across calendars.
public struct SubtaskSummary: Identifiable, Equatable {
    public let key: String
    public let label: String
    public let hours: Double
    public var id: String { key }

    public init(key: String, label: String, hours: Double) {
        self.key = key
        self.label = label
        self.hours = hours
    }
}

/// A task's total hours over a window, merged across calendars, with its
/// (also merged) subtasks. Drives the flat, hours-sorted sidebar.
public struct TaskSummary: Identifiable, Equatable {
    public let key: String
    public let label: String
    public let hours: Double
    public var subtasks: [SubtaskSummary]
    public var id: String { key }

    public init(key: String, label: String, hours: Double, subtasks: [SubtaskSummary]) {
        self.key = key
        self.label = label
        self.hours = hours
        self.subtasks = subtasks
    }
}

// MARK: - Hierarchy tree (for the selector)

public struct SubtaskNode: Identifiable, Equatable {
    public let key: String
    public let label: String
    public var id: String { key }
}

public struct TaskNode: Identifiable, Equatable {
    public let key: String
    public let label: String
    public var subtasks: [SubtaskNode]
    public var id: String { key }
}

public struct CalendarNode: Identifiable, Equatable {
    public let key: String
    public let label: String
    public var tasks: [TaskNode]
    public var colorHex: String? = nil
    public var id: String { key }
}

extension Database {

    // MARK: Series & totals

    private func whereClause(_ sel: HierarchySelection,
                             from: String,
                             to: String) -> (sql: String, binds: [String]) {
        var clauses = ["date >= ?", "date <= ?"]
        var binds = [from, to]
        if let c = sel.calendarKey { clauses.append("calendar_key = ?"); binds.append(c) }
        if let t = sel.taskKey { clauses.append("task_key = ?"); binds.append(t) }
        if let s = sel.subtaskKey { clauses.append("subtask_key = ?"); binds.append(s) }
        return (clauses.joined(separator: " AND "), binds)
    }

    /// Daily hours + occurrences for a selection over `[from, to]` (inclusive).
    public func dailySeries(selection: HierarchySelection,
                            from: String,
                            to: String) throws -> [DailyPoint] {
        let (whereSQL, binds) = whereClause(selection, from: from, to: to)
        let sql = """
        SELECT date, SUM(duration_seconds), SUM(occurrence_count)
        FROM daily_time
        WHERE \(whereSQL)
        GROUP BY date
        ORDER BY date;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        for (i, value) in binds.enumerated() {
            bindText(stmt, Int32(i + 1), value)
        }

        var points: [DailyPoint] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let date = columnText(stmt, 0) ?? ""
            let seconds = sqlite3_column_int64(stmt, 1)
            let occ = sqlite3_column_int64(stmt, 2)
            points.append(DailyPoint(date: date,
                                     hours: Double(seconds) / 3600.0,
                                     occurrences: Int(occ)))
        }
        return points
    }

    /// Total hours + occurrences for a selection over `[from, to]` (inclusive).
    public func totals(selection: HierarchySelection,
                       from: String,
                       to: String) throws -> RangeTotals {
        let (whereSQL, binds) = whereClause(selection, from: from, to: to)
        let sql = """
        SELECT COALESCE(SUM(duration_seconds), 0), COALESCE(SUM(occurrence_count), 0)
        FROM daily_time
        WHERE \(whereSQL);
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        for (i, value) in binds.enumerated() {
            bindText(stmt, Int32(i + 1), value)
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return .zero }
        let seconds = sqlite3_column_int64(stmt, 0)
        let occ = sqlite3_column_int64(stmt, 1)
        return RangeTotals(totalHours: Double(seconds) / 3600.0, occurrences: Int(occ))
    }

    /// Per-calendar daily hours for a selection over `[from, to]` (inclusive),
    /// used to render stacked, calendar-colored bars.
    public func dailySeriesByCalendar(selection: HierarchySelection,
                                      from: String,
                                      to: String) throws -> [CalendarDailyPoint] {
        let (whereSQL, binds) = whereClause(selection, from: from, to: to)
        let sql = """
        SELECT date, calendar_key, MAX(calendar_label), MAX(calendar_color),
               SUM(duration_seconds)
        FROM daily_time
        WHERE \(whereSQL)
        GROUP BY date, calendar_key
        ORDER BY date, MAX(calendar_label);
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        for (i, value) in binds.enumerated() {
            bindText(stmt, Int32(i + 1), value)
        }

        var points: [CalendarDailyPoint] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let date = columnText(stmt, 0) ?? ""
            let calKey = columnText(stmt, 1) ?? ""
            let calLabel = columnText(stmt, 2) ?? ""
            let color = columnText(stmt, 3)
            let seconds = sqlite3_column_int64(stmt, 4)
            points.append(CalendarDailyPoint(date: date,
                                             calendarKey: calKey,
                                             calendarLabel: calLabel,
                                             colorHex: color,
                                             hours: Double(seconds) / 3600.0))
        }
        return points
    }

    /// Per-segment daily hours for the weekly stacked chart. When `dimension`
    /// is `.task`, each segment is one activity (namespaced `calendar_key` +
    /// `task_key` so tasks never collide across calendars); when `.subtask`,
    /// each segment is a subtask of the scoped activity, and events with no
    /// subtask fold into a single "(no subtask)" segment.
    public func segmentDailySeries(selection: HierarchySelection,
                                   dimension: SegmentDimension,
                                   from: String,
                                   to: String) throws -> [SegmentDailyPoint] {
        let (whereSQL, binds) = whereClause(selection, from: from, to: to)
        let sql: String
        switch dimension {
        case .task:
            sql = """
            SELECT date, task_key, MAX(task_label), SUM(duration_seconds)
            FROM daily_time
            WHERE \(whereSQL)
            GROUP BY date, task_key
            ORDER BY date;
            """
        case .subtask:
            sql = """
            SELECT date, subtask_key, MAX(subtask_label), SUM(duration_seconds)
            FROM daily_time
            WHERE \(whereSQL)
            GROUP BY date, subtask_key
            ORDER BY date;
            """
        }
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        for (i, value) in binds.enumerated() {
            bindText(stmt, Int32(i + 1), value)
        }

        var points: [SegmentDailyPoint] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let date = columnText(stmt, 0) ?? ""
            let key: String
            let label: String
            let seconds: Int64
            switch dimension {
            case .task:
                let taskKey = columnText(stmt, 1) ?? ""
                key = taskKey
                label = columnText(stmt, 2) ?? taskKey
                seconds = sqlite3_column_int64(stmt, 3)
            case .subtask:
                let subKey = columnText(stmt, 1)
                key = subKey ?? SegmentDailyPoint.noSubtaskKey
                label = columnText(stmt, 2) ?? (subKey == nil ? "(no subtask)" : subKey!)
                seconds = sqlite3_column_int64(stmt, 3)
            }
            points.append(SegmentDailyPoint(date: date,
                                            segmentKey: key,
                                            segmentLabel: label,
                                            hours: Double(seconds) / 3600.0))
        }
        return points
    }

    // MARK: Hierarchy tree

    /// Builds the Calendar → Task → Subtask tree from all stored rows.
    public func hierarchy() throws -> [CalendarNode] {
        let sql = """
        SELECT DISTINCT calendar_key, calendar_label, task_key, task_label,
                        subtask_key, subtask_label, calendar_color
        FROM daily_time
        ORDER BY calendar_label, task_label, subtask_label;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        var calendars: [String: CalendarNode] = [:]
        var calendarColor: [String: String] = [:]
        var calendarOrder: [String] = []
        // task key is only unique within a calendar → namespace it
        var taskIndex: [String: [String: TaskNode]] = [:]
        var subtaskSeen: Set<String> = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let calKey = columnText(stmt, 0) ?? ""
            let calLabel = columnText(stmt, 1) ?? ""
            let taskKey = columnText(stmt, 2) ?? ""
            let taskLabel = columnText(stmt, 3) ?? ""
            let subKey = columnText(stmt, 4)
            let subLabel = columnText(stmt, 5)
            let color = columnText(stmt, 6)

            if calendars[calKey] == nil {
                calendars[calKey] = CalendarNode(key: calKey, label: calLabel, tasks: [])
                calendarOrder.append(calKey)
                taskIndex[calKey] = [:]
            }
            if let color, calendarColor[calKey] == nil {
                calendarColor[calKey] = color
            }
            if taskIndex[calKey]?[taskKey] == nil {
                taskIndex[calKey]?[taskKey] = TaskNode(key: taskKey, label: taskLabel, subtasks: [])
            }
            if let subKey, let subLabel {
                let dedupe = "\(calKey)\u{1F}\(taskKey)\u{1F}\(subKey)"
                if !subtaskSeen.contains(dedupe) {
                    subtaskSeen.insert(dedupe)
                    taskIndex[calKey]?[taskKey]?.subtasks.append(
                        SubtaskNode(key: subKey, label: subLabel))
                }
            }
        }

        return calendarOrder.map { calKey in
            var node = calendars[calKey]!
            let tasks = (taskIndex[calKey] ?? [:]).values
                .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
            node.tasks = tasks
            node.colorHex = calendarColor[calKey]
            return node
        }
    }

    // MARK: Flat task list

    /// Tasks over `[from, to]` (inclusive), merged across calendars by
    /// `task_key`, each with its (also cross-calendar-merged) subtasks. Tasks
    /// are sorted by total hours descending (tie-break by label); subtasks the
    /// same. Only real (non-null) subtasks are included, so tasks with no
    /// subtasks yield an empty list.
    public func taskSummaries(from: String, to: String) throws -> [TaskSummary] {
        try taskSummaries(windowFrom: from, windowTo: to,
                          hoursFrom: from, hoursTo: to)
    }

    /// Like `taskSummaries(from:to:)` but with the *list membership* range
    /// (`[windowFrom, windowTo]`) decoupled from the *hours* range
    /// (`[hoursFrom, hoursTo]`). Every task/subtask that appears anywhere in the
    /// window is listed, but its hours count only the rows within the hours
    /// range (a subset of the window). Ranking uses those counted hours, so
    /// activities with no time in the hours range surface at the bottom
    /// (alphabetically) with `0` hours. Drives a sidebar that lists the window's
    /// activities while tallying only the current week.
    public func taskSummaries(windowFrom: String, windowTo: String,
                              hoursFrom: String, hoursTo: String) throws -> [TaskSummary] {
        // Labels are picked from the most recent date within the window (via
        // `MAX(date || sep || label)`, using the fixed-width `yyyy-MM-dd` prefix
        // to order), so an activity's newest emoji wins when it varies over time.
        let sql = """
        SELECT task_key, MAX(date || char(31) || task_label), subtask_key,
               MAX(CASE WHEN subtask_label IS NOT NULL
                        THEN date || char(31) || subtask_label END),
               SUM(CASE WHEN date >= ? AND date <= ? THEN duration_seconds ELSE 0 END)
        FROM daily_time
        WHERE date >= ? AND date <= ?
        GROUP BY task_key, subtask_key
        ORDER BY task_key;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, hoursFrom)
        bindText(stmt, 2, hoursTo)
        bindText(stmt, 3, windowFrom)
        bindText(stmt, 4, windowTo)

        struct Acc {
            var label: String
            var hours: Double = 0
            var subHours: [String: Double] = [:]
            var subLabels: [String: String] = [:]
        }
        var tasks: [String: Acc] = [:]
        var order: [String] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let taskKey = columnText(stmt, 0) ?? ""
            let taskLabel = Self.decodeMostRecentLabel(columnText(stmt, 1)) ?? taskKey
            let subKey = columnText(stmt, 2)
            let subLabel = Self.decodeMostRecentLabel(columnText(stmt, 3))
            let hours = Double(sqlite3_column_int64(stmt, 4)) / 3600.0

            if tasks[taskKey] == nil {
                tasks[taskKey] = Acc(label: taskLabel)
                order.append(taskKey)
            }
            tasks[taskKey]?.hours += hours
            if let subKey {
                tasks[taskKey]?.subHours[subKey, default: 0] += hours
                tasks[taskKey]?.subLabels[subKey] = subLabel ?? subKey
            }
        }

        let summaries = order.map { key -> TaskSummary in
            let acc = tasks[key]!
            let subtasks = acc.subHours.keys
                .map { SubtaskSummary(key: $0,
                                      label: acc.subLabels[$0] ?? $0,
                                      hours: acc.subHours[$0] ?? 0) }
                .sorted { rankHours($0.hours, $0.label, $1.hours, $1.label) }
            return TaskSummary(key: key, label: acc.label,
                               hours: acc.hours, subtasks: subtasks)
        }
        return summaries.sorted { rankHours($0.hours, $0.label, $1.hours, $1.label) }
    }

    /// Orders by hours descending, tie-breaking on label ascending.
    private func rankHours(_ ha: Double, _ la: String,
                           _ hb: Double, _ lb: String) -> Bool {
        if ha != hb { return ha > hb }
        return la.localizedCaseInsensitiveCompare(lb) == .orderedAscending
    }

    /// Decodes a `date || U+001F || label` value produced by a most-recent-date
    /// `MAX(...)` aggregate, returning just the label. Returns `nil` for `nil`
    /// input (e.g. the "(no subtask)" bucket).
    static func decodeMostRecentLabel(_ encoded: String?) -> String? {
        guard let encoded else { return nil }
        guard let sep = encoded.range(of: "\u{1F}") else { return encoded }
        return String(encoded[sep.upperBound...])
    }
}

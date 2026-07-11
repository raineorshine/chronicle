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

/// Totals for a selected range.
public struct RangeTotals: Equatable {
    public let totalHours: Double
    public let occurrences: Int

    public static let zero = RangeTotals(totalHours: 0, occurrences: 0)
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

    // MARK: Hierarchy tree

    /// Builds the Calendar → Task → Subtask tree from all stored rows.
    public func hierarchy() throws -> [CalendarNode] {
        let sql = """
        SELECT DISTINCT calendar_key, calendar_label, task_key, task_label,
                        subtask_key, subtask_label
        FROM daily_time
        ORDER BY calendar_label, task_label, subtask_label;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        var calendars: [String: CalendarNode] = [:]
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

            if calendars[calKey] == nil {
                calendars[calKey] = CalendarNode(key: calKey, label: calLabel, tasks: [])
                calendarOrder.append(calKey)
                taskIndex[calKey] = [:]
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
            return node
        }
    }
}

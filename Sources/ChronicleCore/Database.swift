import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum DatabaseError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String)
    case step(String)

    public var description: String {
        switch self {
        case .open(let m): return "SQLite open failed: \(m)"
        case .prepare(let m): return "SQLite prepare failed: \(m)"
        case .step(let m): return "SQLite step failed: \(m)"
        }
    }
}

/// Thin wrapper over the system SQLite3 library. Owns the `daily_time` schema,
/// the rolling-window rebuild, and read queries used by the viewer.
public final class Database {
    private var db: OpaquePointer?

    public init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly
            ? SQLITE_OPEN_READONLY
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw DatabaseError.open(msg)
        }
        if !readOnly {
            try exec("PRAGMA journal_mode = WAL;")
            try exec("PRAGMA foreign_keys = ON;")
            try createSchema()
            try migrate()
        }
        try createAliasView()
    }

    deinit {
        sqlite3_close(db)
    }

    private func createSchema() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS daily_time (
            date TEXT NOT NULL,

            calendar_key TEXT NOT NULL,
            calendar_label TEXT NOT NULL,
            calendar_color TEXT,

            task_key TEXT NOT NULL,
            task_label TEXT NOT NULL,

            subtask_key TEXT,
            subtask_label TEXT,

            duration_seconds INTEGER NOT NULL,
            occurrence_count INTEGER NOT NULL,

            PRIMARY KEY (
                date,
                calendar_key,
                task_key,
                subtask_key
            )
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_daily_time_date ON daily_time(date);")
        try exec("""
        CREATE INDEX IF NOT EXISTS idx_daily_time_hier
            ON daily_time(calendar_key, task_key, subtask_key);
        """)
    }

    /// Applies additive migrations to databases created by older versions.
    private func migrate() throws {
        if !columnExists(table: "daily_time", column: "calendar_color") {
            try exec("ALTER TABLE daily_time ADD COLUMN calendar_color TEXT;")
        }
    }

    private func columnExists(table: String, column: String) -> Bool {
        guard let stmt = try? prepare("PRAGMA table_info(\(table));") else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if columnText(stmt, 1) == column { return true }
        }
        return false
    }

    // MARK: - Aliases (read-time canonicalization)

    /// Creates the connection-local `alias_map` table and the `canonical_time`
    /// view read by every query. `canonical_time` rewrites each row's
    /// task/subtask key+label to its alias target (when one matches), so renamed
    /// tasks roll up as one activity. Temp objects live in the per-connection
    /// temp database, so this works even for read-only connections and never
    /// touches the on-disk schema. `alias_map` starts empty (a pass-through);
    /// `setAliases` repopulates it and the view reflects the change live.
    private func createAliasView() throws {
        try exec("""
        CREATE TEMP TABLE IF NOT EXISTS alias_map (
            from_task_key TEXT NOT NULL,
            from_subtask_key TEXT,
            to_task_key TEXT NOT NULL,
            to_task_label TEXT NOT NULL,
            to_subtask_key TEXT,
            to_subtask_label TEXT
        );
        """)
        try exec("""
        CREATE TEMP VIEW IF NOT EXISTS canonical_time AS
        SELECT
            d.date,
            d.calendar_key,
            d.calendar_label,
            d.calendar_color,
            COALESCE(a.to_task_key, d.task_key) AS task_key,
            COALESCE(a.to_task_label, d.task_label) AS task_label,
            CASE WHEN a.from_task_key IS NOT NULL
                 THEN a.to_subtask_key ELSE d.subtask_key END AS subtask_key,
            CASE WHEN a.from_task_key IS NOT NULL
                 THEN a.to_subtask_label ELSE d.subtask_label END AS subtask_label,
            d.duration_seconds,
            d.occurrence_count
        FROM daily_time d
        LEFT JOIN alias_map a
            ON d.task_key = a.from_task_key
            AND d.subtask_key IS a.from_subtask_key;
        """)
    }

    /// Replaces the active alias set. Rows in `daily_time` whose
    /// `(task_key, subtask_key)` matches an alias's `from` are read through
    /// `canonical_time` as the alias's `to` identity.
    public func setAliases(_ aliases: [ResolvedAlias]) throws {
        try exec("DELETE FROM alias_map;")
        guard !aliases.isEmpty else { return }
        let sql = """
        INSERT INTO alias_map
            (from_task_key, from_subtask_key, to_task_key, to_task_label,
             to_subtask_key, to_subtask_label)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        for a in aliases {
            sqlite3_reset(stmt)
            bindText(stmt, 1, a.fromTaskKey)
            bindNullableText(stmt, 2, a.fromSubtaskKey)
            bindText(stmt, 3, a.toTaskKey)
            bindText(stmt, 4, a.toTaskLabel)
            bindNullableText(stmt, 5, a.toSubtaskKey)
            bindNullableText(stmt, 6, a.toSubtaskLabel)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw stepError() }
        }
    }

    // MARK: - Write

    /// Deletes all rows within `[firstDate, lastDate]` and inserts `rows`, in a
    /// single transaction. This is the rolling-window rebuild.
    public func replaceWindow(rows: [DailyRow],
                              firstDate: String,
                              lastDate: String) throws {
        try exec("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try deleteWindow(firstDate: firstDate, lastDate: lastDate)
            try insert(rows: rows)
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func deleteWindow(firstDate: String, lastDate: String) throws {
        let sql = "DELETE FROM daily_time WHERE date >= ? AND date <= ?;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, firstDate)
        bindText(stmt, 2, lastDate)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw stepError() }
    }

    private func insert(rows: [DailyRow]) throws {
        let sql = """
        INSERT INTO daily_time
            (date, calendar_key, calendar_label, calendar_color, task_key, task_label,
             subtask_key, subtask_label, duration_seconds, occurrence_count)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        for row in rows {
            sqlite3_reset(stmt)
            bindText(stmt, 1, row.date)
            bindText(stmt, 2, row.calendarKey)
            bindText(stmt, 3, row.calendarLabel)
            bindNullableText(stmt, 4, row.calendarColor)
            bindText(stmt, 5, row.taskKey)
            bindText(stmt, 6, row.taskLabel)
            bindNullableText(stmt, 7, row.subtaskKey)
            bindNullableText(stmt, 8, row.subtaskLabel)
            sqlite3_bind_int64(stmt, 9, Int64(row.durationSeconds))
            sqlite3_bind_int64(stmt, 10, Int64(row.occurrenceCount))
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw stepError() }
        }
    }

    // MARK: - Low-level helpers

    func exec(_ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errmsg) != SQLITE_OK {
            let msg = errmsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errmsg)
            throw DatabaseError.step(msg)
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DatabaseError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    func stepError() -> DatabaseError {
        DatabaseError.step(String(cString: sqlite3_errmsg(db)))
    }

    func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    func bindNullableText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    var handle: OpaquePointer? { db }
}

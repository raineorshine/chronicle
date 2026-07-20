import Foundation

/// User configuration, persisted as JSON at `ChroniclePaths.configURL`.
public struct ChronicleConfig: Codable, Equatable {
    /// Calendar display names (as shown in Apple Calendar) to include.
    /// Only events from these calendars are extracted. Empty means "none".
    public var calendarAllowlist: [String]

    /// Substrings treated as Task/Subtask separators. A title is split on the
    /// earliest (leftmost) occurrence of any of these. Defaults to `" - "` and
    /// `" | "`; the surrounding spaces keep ordinary hyphenated words intact.
    public var subtaskSeparators: [String]

    /// Calendar display names (as shown in Apple Calendar) treated as
    /// *subtractive*: their overlap is removed from events in other calendars,
    /// while their own time is still counted in full. Matched case-insensitively.
    /// A subtractive calendar is always extracted, even if not in the allowlist.
    public var subtractiveCalendars: [String]

    /// Calendar display names (as shown in Apple Calendar) that render as a
    /// single whole-calendar segment at the top level, instead of breaking out
    /// into individual task segments. Matched case-insensitively. Display-only:
    /// changing this never triggers re-extraction. Calendars absent from this
    /// list use the default "by task" segmentation.
    public var wholeCalendarSegments: [String]

    /// Rolling window: how many days into the past to rebuild.
    public var windowPastDays: Int

    /// Rolling window: how many days into the future to rebuild.
    public var windowFutureDays: Int

    /// Per-task color overrides, keyed by `task_key`, as `#RRGGBB` strings.
    /// Display-only: changing a color never triggers re-extraction. Tasks
    /// without an entry fall back to a stable auto-color derived from their key.
    public var taskColors: [String: String]

    /// Weekday on which the sidebar/legend tallies switch from the previous
    /// (just-completed) week to the current, in-progress week. Uses Foundation's
    /// weekday numbering (1 = Sunday … 7 = Saturday). Before this weekday the
    /// tallies cover the whole previous week (Mon–Sun); on or after it they cover
    /// the current week (Mon–today). Defaults to `6` (Friday). Display-only:
    /// changing it never triggers re-extraction.
    public var weeklyMetricsCutoff: Int

    public init(calendarAllowlist: [String] = [],
                subtaskSeparators: [String] = [" - ", " | "],
                subtractiveCalendars: [String] = [],
                wholeCalendarSegments: [String] = [],
                windowPastDays: Int = 60,
                windowFutureDays: Int = 14,
                taskColors: [String: String] = [:],
                weeklyMetricsCutoff: Int = 6) {
        self.calendarAllowlist = calendarAllowlist
        self.subtaskSeparators = subtaskSeparators
        self.subtractiveCalendars = subtractiveCalendars
        self.wholeCalendarSegments = wholeCalendarSegments
        self.windowPastDays = windowPastDays
        self.windowFutureDays = windowFutureDays
        self.taskColors = taskColors
        self.weeklyMetricsCutoff = weeklyMetricsCutoff
    }

    public static let `default` = ChronicleConfig()

    private enum CodingKeys: String, CodingKey {
        case calendarAllowlist, subtaskSeparators, subtractiveCalendars
        case wholeCalendarSegments, windowPastDays, windowFutureDays, taskColors
        case weeklyMetricsCutoff
        // Legacy single-separator key, decoded for migration only.
        case subtaskSeparator
    }

    /// Tolerant decoding so configs written by older versions (which lack the
    /// newer keys) still load, falling back to defaults for any missing field.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ChronicleConfig.default
        calendarAllowlist = try c.decodeIfPresent([String].self, forKey: .calendarAllowlist) ?? d.calendarAllowlist
        // Prefer the new list; migrate a legacy single separator; else default.
        if let separators = try c.decodeIfPresent([String].self, forKey: .subtaskSeparators) {
            subtaskSeparators = separators
        } else if let legacy = try c.decodeIfPresent(String.self, forKey: .subtaskSeparator) {
            subtaskSeparators = [legacy]
        } else {
            subtaskSeparators = d.subtaskSeparators
        }
        subtractiveCalendars = try c.decodeIfPresent([String].self, forKey: .subtractiveCalendars) ?? d.subtractiveCalendars
        wholeCalendarSegments = try c.decodeIfPresent([String].self, forKey: .wholeCalendarSegments) ?? d.wholeCalendarSegments
        windowPastDays = try c.decodeIfPresent(Int.self, forKey: .windowPastDays) ?? d.windowPastDays
        windowFutureDays = try c.decodeIfPresent(Int.self, forKey: .windowFutureDays) ?? d.windowFutureDays
        taskColors = try c.decodeIfPresent([String: String].self, forKey: .taskColors) ?? d.taskColors
        weeklyMetricsCutoff = try c.decodeIfPresent(Int.self, forKey: .weeklyMetricsCutoff) ?? d.weeklyMetricsCutoff
    }

    /// Custom encoder that omits the legacy `subtaskSeparator` key, writing only
    /// the current `subtaskSeparators` list.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(calendarAllowlist, forKey: .calendarAllowlist)
        try c.encode(subtaskSeparators, forKey: .subtaskSeparators)
        try c.encode(subtractiveCalendars, forKey: .subtractiveCalendars)
        try c.encode(wholeCalendarSegments, forKey: .wholeCalendarSegments)
        try c.encode(windowPastDays, forKey: .windowPastDays)
        try c.encode(windowFutureDays, forKey: .windowFutureDays)
        try c.encode(taskColors, forKey: .taskColors)
        try c.encode(weeklyMetricsCutoff, forKey: .weeklyMetricsCutoff)
    }

    /// Loads config from disk. If the file is missing, writes and returns the
    /// default so the user has a template to edit.
    public static func load() throws -> ChronicleConfig {
        let url = ChroniclePaths.configURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try ChroniclePaths.ensureSupportDirectory()
            let config = ChronicleConfig.default
            try config.save()
            return config
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ChronicleConfig.self, from: data)
    }

    public func save() throws {
        try ChroniclePaths.ensureSupportDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: ChroniclePaths.configURL, options: .atomic)
    }
}

import Foundation

/// User configuration, persisted as JSON at `ChroniclePaths.configURL`.
public struct ChronicleConfig: Codable, Equatable {
    /// Calendar display names (as shown in Apple Calendar) to include.
    /// Only events from these calendars are extracted. Empty means "none".
    public var calendarAllowlist: [String]

    /// The only substring treated as a Task/Subtask separator.
    public var subtaskSeparator: String

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

    /// Ordered title-rename chains. Each chain is a list of raw event titles
    /// where the **last** entry is the canonical (newest) title and every
    /// earlier entry is an alias that merges into it. A chain models a task
    /// renamed one or more times over time, e.g.
    /// `["VP of Engineering", "em - Code Reviews", "em - Engineering Lead"]`.
    /// Display-only: applied at read time, so changing it never re-extracts.
    public var aliasChains: [[String]]

    public init(calendarAllowlist: [String] = [],
                subtaskSeparator: String = " - ",
                subtractiveCalendars: [String] = [],
                wholeCalendarSegments: [String] = [],
                windowPastDays: Int = 60,
                windowFutureDays: Int = 14,
                taskColors: [String: String] = [:],
                aliasChains: [[String]] = []) {
        self.calendarAllowlist = calendarAllowlist
        self.subtaskSeparator = subtaskSeparator
        self.subtractiveCalendars = subtractiveCalendars
        self.wholeCalendarSegments = wholeCalendarSegments
        self.windowPastDays = windowPastDays
        self.windowFutureDays = windowFutureDays
        self.taskColors = taskColors
        self.aliasChains = aliasChains
    }

    public static let `default` = ChronicleConfig()

    private enum CodingKeys: String, CodingKey {
        case calendarAllowlist, subtaskSeparator, subtractiveCalendars
        case wholeCalendarSegments, windowPastDays, windowFutureDays, taskColors
        case aliasChains
    }

    /// Tolerant decoding so configs written by older versions (which lack the
    /// newer keys) still load, falling back to defaults for any missing field.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ChronicleConfig.default
        calendarAllowlist = try c.decodeIfPresent([String].self, forKey: .calendarAllowlist) ?? d.calendarAllowlist
        subtaskSeparator = try c.decodeIfPresent(String.self, forKey: .subtaskSeparator) ?? d.subtaskSeparator
        subtractiveCalendars = try c.decodeIfPresent([String].self, forKey: .subtractiveCalendars) ?? d.subtractiveCalendars
        wholeCalendarSegments = try c.decodeIfPresent([String].self, forKey: .wholeCalendarSegments) ?? d.wholeCalendarSegments
        windowPastDays = try c.decodeIfPresent(Int.self, forKey: .windowPastDays) ?? d.windowPastDays
        windowFutureDays = try c.decodeIfPresent(Int.self, forKey: .windowFutureDays) ?? d.windowFutureDays
        taskColors = try c.decodeIfPresent([String: String].self, forKey: .taskColors) ?? d.taskColors
        aliasChains = try c.decodeIfPresent([[String]].self, forKey: .aliasChains) ?? d.aliasChains
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

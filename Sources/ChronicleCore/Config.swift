import Foundation

/// User configuration, persisted as JSON at `ChroniclePaths.configURL`.
public struct ChronicleConfig: Codable, Equatable {
    /// Calendar display names (as shown in Apple Calendar) to include.
    /// Only events from these calendars are extracted. Empty means "none".
    public var calendarAllowlist: [String]

    /// The only substring treated as a Task/Subtask separator.
    public var subtaskSeparator: String

    /// Rolling window: how many days into the past to rebuild.
    public var windowPastDays: Int

    /// Rolling window: how many days into the future to rebuild.
    public var windowFutureDays: Int

    public init(calendarAllowlist: [String] = [],
                subtaskSeparator: String = " - ",
                windowPastDays: Int = 60,
                windowFutureDays: Int = 14) {
        self.calendarAllowlist = calendarAllowlist
        self.subtaskSeparator = subtaskSeparator
        self.windowPastDays = windowPastDays
        self.windowFutureDays = windowFutureDays
    }

    public static let `default` = ChronicleConfig()

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

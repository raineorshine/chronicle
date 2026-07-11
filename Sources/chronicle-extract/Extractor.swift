import Foundation
import ChronicleCore

/// The daily extraction job. Delegates EventKit access + aggregation to
/// `ChronicleCore.CalendarExtractor` so the app and CLI share one code path.
enum Extractor {

    static func run() async -> Int32 {
        do {
            let config = try ChronicleConfig.load()
            log("Loaded config: allowlist=\(config.calendarAllowlist), "
                + "window=-\(config.windowPastDays)/+\(config.windowFutureDays) days")

            try ChroniclePaths.ensureSupportDirectory()

            let extractor = CalendarExtractor()
            try await extractor.requestAccess()

            let summary = try extractor.extract(config: config,
                                                databasePath: ChroniclePaths.databaseURL.path)
            log("Available calendars: \(summary.availableCalendars)")
            if summary.includedCalendars.isEmpty {
                log("WARNING: no calendars matched the allowlist. "
                    + "Window was cleared with no data.")
            } else {
                log("Included calendars: \(summary.includedCalendars)")
            }
            log("Wrote \(summary.rowCount) rows for window "
                + "\(summary.firstDate) … \(summary.lastDate) "
                + "to \(ChroniclePaths.databaseURL.path)")
            return 0
        } catch {
            log("ERROR: \(error)")
            return 1
        }
    }

    // MARK: - Demo seeding

    /// Populates the database with synthetic data (no Calendar access needed).
    /// Data lands inside the rolling window, so a real run overwrites it.
    static func runDemo() -> Int32 {
        do {
            let config = try ChronicleConfig.load()
            let calendar = Calendar.current
            let window = ExtractionWindow.rolling(pastDays: config.windowPastDays,
                                                  futureDays: config.windowFutureDays,
                                                  calendar: calendar)
            let bounds = window.dateBounds(calendar: calendar)
            log("DEMO MODE: seeding synthetic data into window "
                + "\(bounds.first) … \(bounds.last)")

            let events = SyntheticData.events(calendar: calendar)
            let rows = DateAggregator(calendar: calendar).aggregate(events, window: window)

            try ChroniclePaths.ensureSupportDirectory()
            let db = try Database(path: ChroniclePaths.databaseURL.path)
            try db.replaceWindow(rows: rows, firstDate: bounds.first, lastDate: bounds.last)
            log("DEMO: wrote \(rows.count) rows to \(ChroniclePaths.databaseURL.path)")
            return 0
        } catch {
            log("ERROR: \(error)")
            return 1
        }
    }

    // MARK: - Logging

    private static func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("[\(ts)] \(message)\n".utf8))
    }
}

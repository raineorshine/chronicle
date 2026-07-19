import Foundation

/// A half-open clipping window `[start, end)` for extraction.
public struct ExtractionWindow {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    /// Builds a window covering `[today - pastDays, today + futureDays + 1)`
    /// aligned to local midnight, using `calendar`.
    public static func rolling(pastDays: Int,
                               futureDays: Int,
                               now: Date = Date(),
                               calendar: Calendar) -> ExtractionWindow {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -pastDays, to: today)!
        // Inclusive of the last future day → end is the following midnight.
        let end = calendar.date(byAdding: .day, value: futureDays + 1, to: today)!
        return ExtractionWindow(start: start, end: end)
    }

    /// The inclusive first/last local dates (yyyy-MM-dd) covered by the window.
    public func dateBounds(calendar: Calendar) -> (first: String, last: String) {
        let formatter = DateAggregator.dateFormatter(calendar: calendar)
        let lastDay = calendar.date(byAdding: .day, value: -1, to: end) ?? start
        return (formatter.string(from: start), formatter.string(from: lastDay))
    }
}

/// Aggregates events into `daily_time` rows following the spec's rules:
/// skip all-day events, clip to the window, split across local midnight,
/// sum per-day durations, and count one occurrence on the event's start day.
public struct DateAggregator {
    public let calendar: Calendar

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    static func dateFormatter(calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    private struct Key: Hashable {
        let date: String
        let calendarKey: String
        let taskKey: String
        let subtaskKey: String?
    }

    public func aggregate(_ events: [EventInput],
                          window: ExtractionWindow) -> [DailyRow] {
        let formatter = Self.dateFormatter(calendar: calendar)
        var buckets: [Key: DailyRow] = [:]

        func bucket(for date: String, event: EventInput) -> Key {
            Key(date: date,
                calendarKey: event.calendar.key,
                taskKey: event.title.task.key,
                subtaskKey: event.title.subtask?.key)
        }

        for event in events {
            if event.isAllDay { continue }                       // 1. skip all-day

            // 2. clip to the window
            let start = max(event.start, window.start)
            let end = min(event.end, window.end)
            guard end > start else { continue }

            // Occurrence is counted on the (clipped) start day only.
            let occurrenceDay = formatter.string(from: calendar.startOfDay(for: start))

            // 3. split across local midnight into per-day segments
            var segStart = start
            while segStart < end {
                let dayStart = calendar.startOfDay(for: segStart)
                let nextMidnight = calendar.date(byAdding: .day, value: 1, to: dayStart)!
                let segEnd = min(nextMidnight, end)
                let seconds = Int(segEnd.timeIntervalSince(segStart).rounded())
                let dateStr = formatter.string(from: dayStart)
                let key = bucket(for: dateStr, event: event)

                if var row = buckets[key] {
                    row.durationSeconds += seconds
                    if dateStr == occurrenceDay { row.occurrenceCount += 1 }
                    buckets[key] = row
                } else {
                    buckets[key] = DailyRow(
                        date: dateStr,
                        calendarKey: event.calendar.key,
                        calendarLabel: event.calendar.label,
                        calendarColor: event.calendarColor,
                        taskKey: event.title.task.key,
                        taskLabel: event.title.task.label,
                        subtaskKey: event.title.subtask?.key,
                        subtaskLabel: event.title.subtask?.label,
                        durationSeconds: seconds,
                        occurrenceCount: dateStr == occurrenceDay ? 1 : 0)
                }
                segStart = segEnd
            }
        }

        return Array(buckets.values)
    }
}

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

        // Union of all subtractive intervals (clipped to the window, merged),
        // removed from every non-subtractive event below.
        let cuts = subtractiveIntervals(events, window: window)

        func key(for date: String, event: EventInput) -> Key {
            Key(date: date,
                calendarKey: event.calendar.key,
                taskKey: event.title.task.key,
                subtaskKey: event.title.subtask?.key)
        }

        func emptyRow(_ date: String, _ event: EventInput) -> DailyRow {
            DailyRow(date: date,
                     calendarKey: event.calendar.key,
                     calendarLabel: event.calendar.label,
                     calendarColor: event.calendarColor,
                     taskKey: event.title.task.key,
                     taskLabel: event.title.task.label,
                     subtaskKey: event.title.subtask?.key,
                     subtaskLabel: event.title.subtask?.label,
                     durationSeconds: 0,
                     occurrenceCount: 0)
        }

        for event in events {
            if event.isAllDay { continue }                       // 1. skip all-day

            // 2. clip to the window
            let start = max(event.start, window.start)
            let end = min(event.end, window.end)
            guard end > start else { continue }

            // 3. count the single occurrence on the (clipped) start day. This is
            //    independent of subtraction — an overlapped event still occurred.
            let occurrenceDay = formatter.string(from: calendar.startOfDay(for: start))
            buckets[key(for: occurrenceDay, event: event),
                    default: emptyRow(occurrenceDay, event)].occurrenceCount += 1

            // 4. determine the intervals that contribute duration: subtractive
            //    events keep their full span; others have subtractive overlaps
            //    removed (which may split them into several pieces or none).
            let intervals: [(start: Date, end: Date)] = event.isSubtractive
                ? [(start, end)]
                : Self.subtract(base: (start, end), cuts: cuts)

            // 5. split each remaining interval across local midnight and sum.
            for interval in intervals {
                var segStart = interval.start
                while segStart < interval.end {
                    let dayStart = calendar.startOfDay(for: segStart)
                    let nextMidnight = calendar.date(byAdding: .day, value: 1, to: dayStart)!
                    let segEnd = min(nextMidnight, interval.end)
                    let seconds = Int(segEnd.timeIntervalSince(segStart).rounded())
                    let dateStr = formatter.string(from: dayStart)
                    buckets[key(for: dateStr, event: event),
                            default: emptyRow(dateStr, event)].durationSeconds += seconds
                    segStart = segEnd
                }
            }
        }

        return Array(buckets.values)
    }

    /// Collects every subtractive event's interval, clips it to the window, and
    /// returns them sorted by start with overlaps merged, ready for `subtract`.
    private func subtractiveIntervals(_ events: [EventInput],
                                      window: ExtractionWindow) -> [(start: Date, end: Date)] {
        var intervals: [(start: Date, end: Date)] = []
        for event in events where event.isSubtractive && !event.isAllDay {
            let start = max(event.start, window.start)
            let end = min(event.end, window.end)
            if end > start { intervals.append((start, end)) }
        }
        intervals.sort { $0.start < $1.start }

        var merged: [(start: Date, end: Date)] = []
        for interval in intervals {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1].end = max(last.end, interval.end)
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    /// Removes `cuts` (assumed sorted by start and non-overlapping) from `base`,
    /// returning the remaining sub-intervals in order. May return zero pieces
    /// when the cuts cover `base` entirely.
    static func subtract(base: (start: Date, end: Date),
                         cuts: [(start: Date, end: Date)]) -> [(start: Date, end: Date)] {
        guard base.end > base.start else { return [] }
        var result: [(start: Date, end: Date)] = []
        var cursor = base.start
        for cut in cuts {
            if cut.end <= cursor { continue }        // cut is entirely behind the cursor
            if cut.start >= base.end { break }       // remaining cuts start past base
            let cutStart = max(cut.start, base.start)
            if cutStart > cursor { result.append((cursor, cutStart)) }
            cursor = max(cursor, min(cut.end, base.end))
            if cursor >= base.end { break }
        }
        if cursor < base.end { result.append((cursor, base.end)) }
        return result
    }
}

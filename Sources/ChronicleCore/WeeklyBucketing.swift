import Foundation

/// One (week, segment) cell of the stacked weekly chart.
public struct WeeklyStackPoint: Equatable, Identifiable {
    /// `yyyy-MM-dd` of the week's first day (per the calendar's `firstWeekday`).
    public let weekStart: String
    public let segmentKey: String
    public let segmentLabel: String
    public let hours: Double

    public var id: String { "\(weekStart)|\(segmentKey)" }

    public init(weekStart: String, segmentKey: String, segmentLabel: String, hours: Double) {
        self.weekStart = weekStart
        self.segmentKey = segmentKey
        self.segmentLabel = segmentLabel
        self.hours = hours
    }
}

/// A distinct chart segment (used for the legend / color domain), in display order.
public struct WeeklySegment: Equatable, Identifiable {
    public let key: String
    public let label: String
    /// Total hours across the whole window; drives the top-N ranking.
    public let totalHours: Double
    /// True for the synthetic "Other" bucket that folds the long tail.
    public let isOther: Bool
    /// True for a per-calendar segment folding all of this calendar's tasks
    /// (calendars configured to segment as a whole rather than by task).
    public let isCalendarBucket: Bool
    /// The calendar's own `#RRGGBB` color, for calendar-bucket segments.
    public let colorHex: String?

    public var id: String { key }

    public init(key: String, label: String, totalHours: Double,
                isOther: Bool = false,
                isCalendarBucket: Bool = false,
                colorHex: String? = nil) {
        self.key = key
        self.label = label
        self.totalHours = totalHours
        self.isOther = isOther
        self.isCalendarBucket = isCalendarBucket
        self.colorHex = colorHex
    }
}

/// The fully bucketed result feeding the weeks-on-X stacked chart.
public struct WeeklyStacks: Equatable {
    public let points: [WeeklyStackPoint]
    /// Segments in stacking / legend order (top-N by total hours, then "Other").
    public let segments: [WeeklySegment]
    /// Distinct week starts present, ascending.
    public let weekStarts: [String]

    public static let empty = WeeklyStacks(points: [], segments: [], weekStarts: [])

    public init(points: [WeeklyStackPoint], segments: [WeeklySegment], weekStarts: [String]) {
        self.points = points
        self.segments = segments
        self.weekStarts = weekStarts
    }
}

/// Pure transformation of per-day segment contributions into weekly stacks,
/// keeping only the top-N segments (by total hours over the window) and folding
/// the rest into a single "Other" bucket. Week boundaries follow `calendar`'s
/// `firstWeekday`. Kept free of SwiftUI so it is unit-testable.
public enum WeeklyBucketing {
    public static let otherKey = "\u{1F}other"

    /// Prefix marking a segment key as a whole-calendar segment (see
    /// `bucketByCalendarSegmentMode`). The remainder is the `calendar_key`.
    public static let calendarKeyPrefix = "\u{1F}cal:"

    /// True when `key` identifies a whole-calendar segment.
    public static func isCalendarBucketKey(_ key: String) -> Bool {
        key.hasPrefix(calendarKeyPrefix)
    }

    public static func bucket(_ points: [SegmentDailyPoint],
                              calendar: Calendar,
                              topN: Int = 8,
                              otherLabel: String = "Other") -> WeeklyStacks {
        guard !points.isEmpty else { return .empty }
        let formatter = DateAggregator.dateFormatter(calendar: calendar)

        // Map each daily point to its week start, accumulating per (week, segment).
        struct Cell: Hashable { let week: String; let key: String }
        var cellHours: [Cell: Double] = [:]
        var labelByKey: [String: String] = [:]
        var totalByKey: [String: Double] = [:]
        var weekStartSet: Set<String> = []

        for p in points {
            guard let date = formatter.date(from: p.date),
                  let interval = calendar.dateInterval(of: .weekOfYear, for: date) else { continue }
            let week = formatter.string(from: interval.start)
            weekStartSet.insert(week)
            labelByKey[p.segmentKey] = p.segmentLabel
            totalByKey[p.segmentKey, default: 0] += p.hours
            cellHours[Cell(week: week, key: p.segmentKey), default: 0] += p.hours
        }

        // Rank segments by total hours (desc), tie-break by label for stability.
        let ranked = totalByKey.keys.sorted { a, b in
            let ha = totalByKey[a] ?? 0, hb = totalByKey[b] ?? 0
            if ha != hb { return ha > hb }
            return (labelByKey[a] ?? a) < (labelByKey[b] ?? b)
        }
        let topKeys = Array(ranked.prefix(max(0, topN)))
        let topSet = Set(topKeys)
        let hasOther = ranked.count > topKeys.count

        // Re-key overflow segments to the shared "Other" bucket.
        var merged: [Cell: Double] = [:]
        var otherTotal = 0.0
        for (cell, hours) in cellHours {
            if topSet.contains(cell.key) {
                merged[cell, default: 0] += hours
            } else {
                merged[Cell(week: cell.week, key: otherKey), default: 0] += hours
                otherTotal += hours
            }
        }

        var segments: [WeeklySegment] = topKeys.map {
            WeeklySegment(key: $0, label: labelByKey[$0] ?? $0, totalHours: totalByKey[$0] ?? 0)
        }
        if hasOther {
            segments.append(WeeklySegment(key: otherKey, label: otherLabel,
                                          totalHours: otherTotal, isOther: true))
        }

        let labelForKey: (String) -> String = { key in
            key == otherKey ? otherLabel : (labelByKey[key] ?? key)
        }
        let points = merged
            .map { WeeklyStackPoint(weekStart: $0.key.week, segmentKey: $0.key.key,
                                    segmentLabel: labelForKey($0.key.key), hours: $0.value) }
            .sorted { $0.id < $1.id }

        return WeeklyStacks(points: points,
                            segments: segments,
                            weekStarts: weekStartSet.sorted())
    }

    /// Top-level segmentation driven by per-calendar configuration. Calendars
    /// whose `calendar_key` is in `wholeCalendarKeys` fold all of their tasks
    /// into a single whole-calendar segment; every other calendar's events
    /// surface as individual task segments, merged by `task_key` across all
    /// task-mode calendars. There is no top-N cap and no "Other" bucket.
    /// Segments are ordered for week-to-week visual continuity: task segments
    /// first, alphabetically by `task_key`, then whole-calendar segments
    /// alphabetically by `calendar_key`. Week boundaries follow `calendar`'s
    /// `firstWeekday`. Kept free of SwiftUI so it is unit-testable.
    public static func bucketByCalendarSegmentMode(_ points: [TaskCalendarDailyPoint],
                                                   calendar: Calendar,
                                                   wholeCalendarKeys: Set<String>) -> WeeklyStacks {
        guard !points.isEmpty else { return .empty }
        let formatter = DateAggregator.dateFormatter(calendar: calendar)

        struct Cell: Hashable { let week: String; let key: String }
        var cellHours: [Cell: Double] = [:]
        var totalByKey: [String: Double] = [:]
        var weekStartSet: Set<String> = []

        // Per-segment display metadata, resolved to the most recent date so a
        // task's newest label / a calendar's newest color wins.
        struct Meta { var label: String; var date: String; var color: String? }
        var taskMeta: [String: Meta] = [:]       // key = task_key
        var calendarMeta: [String: Meta] = [:]   // key = calendarKeyPrefix + calendar_key

        for p in points {
            guard p.hours > 0,
                  let date = formatter.date(from: p.date),
                  let interval = calendar.dateInterval(of: .weekOfYear, for: date) else { continue }
            let week = formatter.string(from: interval.start)
            weekStartSet.insert(week)

            let isWhole = wholeCalendarKeys.contains(p.calendarKey)
            let key = isWhole ? calendarKeyPrefix + p.calendarKey : p.taskKey

            if isWhole {
                if calendarMeta[key] == nil || p.date >= calendarMeta[key]!.date {
                    calendarMeta[key] = Meta(label: p.calendarLabel, date: p.date,
                                             color: p.calendarColorHex)
                }
            } else {
                if taskMeta[key] == nil || p.date >= taskMeta[key]!.date {
                    taskMeta[key] = Meta(label: p.taskLabel, date: p.date, color: nil)
                }
            }
            totalByKey[key, default: 0] += p.hours
            cellHours[Cell(week: week, key: key), default: 0] += p.hours
        }

        // Task segments first (alpha by task key), then whole-calendar segments
        // (alpha by calendar key) — stable ordering independent of hours.
        let taskKeys = taskMeta.keys.sorted()
        let calendarKeys = calendarMeta.keys.sorted()

        var segments: [WeeklySegment] = taskKeys.map { key in
            WeeklySegment(key: key, label: taskMeta[key]?.label ?? key,
                          totalHours: totalByKey[key] ?? 0)
        }
        segments += calendarKeys.map { key in
            WeeklySegment(key: key, label: calendarMeta[key]?.label ?? key,
                          totalHours: totalByKey[key] ?? 0,
                          isCalendarBucket: true, colorHex: calendarMeta[key]?.color)
        }

        let labelForKey: (String) -> String = { key in
            taskMeta[key]?.label ?? calendarMeta[key]?.label ?? key
        }
        let stackPoints = cellHours
            .map { WeeklyStackPoint(weekStart: $0.key.week, segmentKey: $0.key.key,
                                    segmentLabel: labelForKey($0.key.key), hours: $0.value) }
            .sorted { $0.id < $1.id }

        return WeeklyStacks(points: stackPoints,
                            segments: segments,
                            weekStarts: weekStartSet.sorted())
    }
}

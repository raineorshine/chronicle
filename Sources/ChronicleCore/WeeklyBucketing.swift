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

    public var id: String { key }

    public init(key: String, label: String, totalHours: Double, isOther: Bool = false) {
        self.key = key
        self.label = label
        self.totalHours = totalHours
        self.isOther = isOther
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
}

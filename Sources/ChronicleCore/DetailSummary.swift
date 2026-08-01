import Foundation

/// One row of the detail page's "Top tasks" list: a chart segment with its total
/// hours across the whole charted window.
public struct SummaryEntry: Equatable, Identifiable {
    public let segmentKey: String
    /// The segment's own label. The UI renders the store's disambiguated display
    /// label instead; this is what ranking ties break on.
    public let label: String
    public let hours: Double

    public var id: String { segmentKey }

    public init(segmentKey: String, label: String, hours: Double) {
        self.segmentKey = segmentKey
        self.label = label
        self.hours = hours
    }
}

/// One row of the detail page's "Top movers" list: a segment's hours in two
/// weeks side by side, ranked by how far it moved between them.
public struct MoverEntry: Equatable, Identifiable {
    public let segmentKey: String
    /// See `SummaryEntry.label`.
    public let label: String
    public let previousHours: Double
    public let currentHours: Double

    public var id: String { segmentKey }

    public var delta: Double { currentHours - previousHours }

    /// The change as a percentage of the previous week, or nil when there is no
    /// baseline to measure against — a segment rising out of zero has moved, but
    /// not by any finite percentage.
    public var percentChange: Double? {
        previousHours > 0 ? delta / previousHours * 100 : nil
    }

    public init(segmentKey: String, label: String, previousHours: Double, currentHours: Double) {
        self.segmentKey = segmentKey
        self.label = label
        self.previousHours = previousHours
        self.currentHours = currentHours
    }
}

/// Pure ranking of already-bucketed weekly stacks into the two lists the detail
/// page shows above its chart. Reads the same `WeeklyStacks` the chart draws, so
/// the summary and the chart can never disagree. Kept free of SwiftUI so it is
/// unit-testable.
public enum DetailSummary {
    /// The smallest change, in hours, that counts as movement (3 minutes). Below
    /// this a segment reads as flat once rounded for display, so listing it as a
    /// "mover" would show an identical before and after.
    public static let moverThreshold = 0.05

    /// The busiest segments over the whole window, most hours first. The "Other"
    /// bucket is left out: it is a synthetic fold of the long tail, not a task
    /// the user can act on.
    public static func topByHours(_ stacks: WeeklyStacks,
                                  limit: Int = 5,
                                  excluding excluded: Set<String> = []) -> [SummaryEntry] {
        stacks.segments
            .filter { !$0.isOther && !excluded.contains($0.key) && $0.totalHours > 0 }
            .sorted { a, b in
                if a.totalHours != b.totalHours { return a.totalHours > b.totalHours }
                return a.label < b.label
            }
            .prefix(limit)
            .map { SummaryEntry(segmentKey: $0.key, label: $0.label, hours: $0.totalHours) }
    }

    /// The segments that changed most between two weeks, biggest absolute swing
    /// first — in either direction, so a task that fell off is as visible as one
    /// that took over. Segments that barely budged (see `moverThreshold`) and the
    /// "Other" bucket are left out.
    public static func topMovers(_ stacks: WeeklyStacks,
                                 previousWeek: String,
                                 currentWeek: String,
                                 limit: Int = 5,
                                 excluding excluded: Set<String> = []) -> [MoverEntry] {
        var previous: [String: Double] = [:]
        var current: [String: Double] = [:]
        for point in stacks.points {
            if point.weekStart == previousWeek {
                previous[point.segmentKey, default: 0] += point.hours
            }
            if point.weekStart == currentWeek {
                current[point.segmentKey, default: 0] += point.hours
            }
        }

        let labels = Dictionary(stacks.segments.map { ($0.key, $0.label) },
                                uniquingKeysWith: { first, _ in first })
        let skipped = Set(stacks.segments.filter(\.isOther).map(\.key)).union(excluded)

        return Set(previous.keys).union(current.keys)
            .subtracting(skipped)
            .map { key in
                MoverEntry(segmentKey: key,
                           label: labels[key] ?? key,
                           previousHours: previous[key] ?? 0,
                           currentHours: current[key] ?? 0)
            }
            .filter { abs($0.delta) >= moverThreshold }
            .sorted { a, b in
                if abs(a.delta) != abs(b.delta) { return abs(a.delta) > abs(b.delta) }
                return a.label < b.label
            }
            .prefix(limit)
            .map { $0 }
    }
}

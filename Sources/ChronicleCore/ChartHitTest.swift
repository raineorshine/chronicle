import Foundation

/// Hit-testing the weekly stacked chart against the geometry it actually draws.
///
/// Weeks are discrete, but the area style joins them with straight lines, so a
/// band's top and bottom edges slope across the gap between two week ticks.
/// Resolving a hover by snapping to the nearest tick and walking that week's
/// stack gives every band a rectangular hit box a half-week wide, which lines up
/// with the drawing only where the segment happens to be flat. These helpers walk
/// the interpolated stack instead. Kept free of SwiftUI so it is unit-testable.
public enum ChartHitTest {

    /// Where a hovered date falls among the chart's week ticks.
    public struct WeekSpan: Equatable {
        /// Index of the tick at or before the hovered date.
        public let left: Int
        /// Index of the tick after it, or `left` again at the last tick.
        public let right: Int
        /// 0 at the `left` tick, 1 at the `right` tick.
        public let fraction: Double

        public init(left: Int, right: Int, fraction: Double) {
            self.left = left
            self.right = right
            self.fraction = fraction
        }

        /// The tick the position belongs to when only whole weeks make sense —
        /// which bar it is inside, and which week's recorded hours to quote.
        public var nearest: Int { fraction < 0.5 ? left : right }
    }

    /// Locates `date` among ascending `weekDates`, clamped to the first and last
    /// tick. Nil only when there are no ticks.
    ///
    /// Clamps rather than rejects because the caller gates on the plot rectangle,
    /// which is exact; a date read back off the axis at the very edge of that
    /// rectangle can land a hair outside the domain, and rejecting it would leave
    /// the outermost pixel column of the chart unhoverable.
    public static func span(at date: Date, in weekDates: [Date]) -> WeekSpan? {
        guard !weekDates.isEmpty else { return nil }
        var left = 0
        while left + 1 < weekDates.count && weekDates[left + 1] <= date { left += 1 }
        let right = min(left + 1, weekDates.count - 1)
        let gap = weekDates[right].timeIntervalSince(weekDates[left])
        let raw = gap > 0 ? date.timeIntervalSince(weekDates[left]) / gap : 0
        return WeekSpan(left: left, right: right, fraction: min(max(raw, 0), 1))
    }

    /// The segment whose band contains `hours` in the stack the chart draws
    /// `fraction` of the way from `leftWeek` to `rightWeek`. Nil below the
    /// baseline, above the top of the stack, or where the band has tapered to
    /// nothing and so draws no pixels to hit.
    ///
    /// Bands are walked bottom→top in segment-key order, the order the chart's
    /// series is built in. `points` may be sparse: a week with no cell for a
    /// segment contributes zero hours there, which is what the chart draws. Pass
    /// one week as both ends for the bar style, whose bands don't slope.
    public static func segmentKey(in points: [WeeklyStackPoint],
                                  from leftWeek: String,
                                  to rightWeek: String,
                                  fraction: Double,
                                  hours: Double) -> String? {
        guard hours >= 0 else { return nil }
        let t = min(max(fraction, 0), 1)
        var left: [String: Double] = [:]
        var right: [String: Double] = [:]
        for p in points {
            if p.weekStart == leftWeek { left[p.segmentKey] = p.hours }
            if p.weekStart == rightWeek { right[p.segmentKey] = p.hours }
        }
        var base = 0.0
        for key in Set(left.keys).union(right.keys).sorted() {
            let lo = left[key] ?? 0
            let height = lo + ((right[key] ?? 0) - lo) * t
            guard height > 0 else { continue }
            if hours < base + height { return key }
            base += height
        }
        return nil
    }

    /// Recorded hours for one (week, segment) cell; zero when that week has no
    /// cell for the segment.
    public static func hours(in points: [WeeklyStackPoint],
                             week: String, segmentKey key: String) -> Double {
        points.first { $0.weekStart == week && $0.segmentKey == key }?.hours ?? 0
    }
}

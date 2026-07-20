import SwiftUI

/// Shared, cross-surface hover highlight state, deliberately kept OFF the large
/// `DashboardStore` so a hover change invalidates only the hover-sensitive
/// surfaces (chart, legend, sidebar rows) instead of the whole view tree that
/// observes the store. Created and owned by `DashboardStore`.
///
/// Hover changes are coalesced to at most one publish per frame: a fast cursor
/// sweep fires `setHighlight` dozens of times a second, and each publish drives
/// an expensive chart re-render, so applying only the latest value roughly once
/// per frame keeps the main thread ahead of the cursor.
@MainActor
final class HoverHighlight: ObservableObject {
    /// The currently highlighted segment key (nil = nothing highlighted).
    @Published private(set) var key: String?

    /// Keys of the segments currently drawn in the chart. Maintained by
    /// `DashboardStore` whenever the chart's segment styles change; used to gate
    /// chart dimming so hovering a row that isn't a current chart segment leaves
    /// the chart fully opaque. Not `@Published`: it only matters alongside a
    /// `key` change, which republishes anyway.
    private var chartSegmentKeys: Set<String> = []

    /// One frame at 60 Hz. Coalescing window for hover publishes.
    private let minInterval: TimeInterval = 1.0 / 60.0
    private var lastApplied = Date.distantPast
    private var pendingKey: String?
    private var hasPending = false
    private var flushScheduled = false

    func setChartSegmentKeys(_ keys: Set<String>) { chartSegmentKeys = keys }

    /// Request a highlight change. Coalesced to at most one publish per frame;
    /// the most recently requested value always wins. A request that matches the
    /// current value (with nothing pending) is dropped, so hovering within one
    /// segment never churns the render tree.
    func setHighlight(_ newKey: String?) {
        if !hasPending && newKey == key { return }
        pendingKey = newKey
        hasPending = true
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        let elapsed = Date().timeIntervalSince(lastApplied)
        if elapsed >= minInterval {
            // Leading edge: idle long enough, apply immediately for instant feel.
            flush()
        } else {
            flushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (minInterval - elapsed)) { [weak self] in
                self?.flush()
            }
        }
    }

    private func flush() {
        flushScheduled = false
        guard hasPending else { return }
        hasPending = false
        lastApplied = Date()
        guard key != pendingKey else { return }
        key = pendingKey
    }

    // MARK: - Derived (used by the chart)

    /// True when the highlight corresponds to a segment actually drawn in the
    /// chart. O(1): reads the maintained `chartSegmentKeys` set.
    var isHighlightActiveInChart: Bool {
        key.map { chartSegmentKeys.contains($0) } ?? false
    }

    /// Opacity for a chart segment given the highlight: the matched segment (or
    /// every segment, when no chart segment is highlighted) stays fully opaque;
    /// others dim.
    func chartOpacity(forSegment segmentKey: String) -> Double {
        (!isHighlightActiveInChart || key == segmentKey) ? 1.0 : 0.55
    }

    /// Whether `candidate` is the currently highlighted key (nil-safe).
    func isHighlighted(_ candidate: String?) -> Bool {
        candidate != nil && candidate == key
    }
}

import Foundation
import SwiftUI
import AppKit
import EventKit
import ChronicleCore

/// Observable state backing the dashboard: hierarchy tree, current scope
/// selection, the trailing week window, and the derived weekly stacked series
/// read from SQLite.
@MainActor
final class DashboardStore: ObservableObject {
    /// Flat, hours-sorted task list (merged across calendars) for the sidebar.
    @Published var taskList: [TaskSummary] = []
    @Published var selection: HierarchySelection = .all
    @Published var selectedNodeID: String = "all"

    /// Visibility of the navigation sidebar column. Bound to the
    /// `NavigationSplitView` so menu commands can expand/collapse it.
    @Published var columnVisibility: NavigationSplitViewVisibility = .all

    /// Number of trailing weeks shown on the X axis (includes the current,
    /// in-progress week). One of `allowedWeekWindows`.
    @Published var weeksWindow: Int = 4

    /// How the weekly chart is rendered (stacked area vs stacked bar). Persisted
    /// to `UserDefaults` so the choice survives relaunches; changed from Settings.
    @Published var chartStyle: ChartStyle =
        ChartStyle(rawValue: UserDefaults.standard.string(forKey: DashboardStore.chartStyleDefaultsKey) ?? "")
        ?? .area {
        didSet {
            guard chartStyle != oldValue else { return }
            UserDefaults.standard.set(chartStyle.rawValue, forKey: DashboardStore.chartStyleDefaultsKey)
        }
    }

    private static let chartStyleDefaultsKey = "chartStyle"

    /// The visual style of the weekly chart, chosen in Settings.
    enum ChartStyle: String, CaseIterable, Identifiable {
        case area
        case bar

        var id: String { rawValue }

        /// User-facing label for the Settings picker.
        var label: String {
            switch self {
            case .area: return "Stacked Area"
            case .bar: return "Stacked Bar"
            }
        }
    }

    /// Bucketed weekly stacks for the current scope + window.
    @Published var stacks: WeeklyStacks = .empty
    /// Segment styles (display label + color) in stacking / legend order.
    @Published var segmentStyles: [SegmentStyle] = []
    /// Per-task color overrides (task_key -> `#RRGGBB`), mirrored from config.
    @Published var taskColors: [String: String] = [:]
    /// Rename chains mirrored from config: each is an ordered list of titles
    /// whose last entry is the canonical (newest) name. Drives the Aliases UI.
    @Published var aliasChains: [[String]] = []
    @Published var totals: RangeTotals = .zero
    @Published var errorMessage: String?
    @Published var isRefreshing = false

    let allowedWeekWindows = [4, 8, 12]

    // MARK: - Calendar picker state

    /// All event calendars (with colors) discovered from EventKit.
    @Published var availableCalendars: [CalendarInfo] = []
    /// Whether Calendar access has been granted.
    @Published var hasCalendarAccess = false
    /// True when access was explicitly denied/restricted, so the system prompt
    /// can no longer be shown and the user must grant access in System Settings.
    @Published var calendarAccessDenied = false
    /// True while calendars are being loaded / access requested.
    @Published var isLoadingCalendars = false

    /// Normalized titles of calendars currently included (mirrors config allowlist).
    private var allowedTitleKeys: Set<String> = []

    /// Normalized titles of calendars currently marked subtractive.
    private var subtractiveTitleKeys: Set<String> = []

    /// Normalized titles (trim + lowercase) of calendars set to whole-calendar
    /// segment mode — mirrors config, used by the picker predicate.
    private var wholeCalendarTitleKeys: Set<String> = []

    /// `calendar_key` form of whole-calendar-mode calendars (matches
    /// `daily_time.calendar_key`), passed to the bucketing to fold their tasks.
    private var wholeCalendarKeys: Set<String> = []

    /// Weekday (Foundation numbering, 1 = Sunday … 7 = Saturday) at which the
    /// sidebar/legend tallies switch from the previous full week to the current
    /// week. Mirrors `ChronicleConfig.weeklyMetricsCutoff`; defaults to Friday.
    private var weeklyMetricsCutoff: Int = 6

    /// Week boundaries always start on Monday, independent of the locale's
    /// default first weekday.
    private let calendar: Calendar = {
        var c = Calendar.current
        c.firstWeekday = 2 // Monday
        return c
    }()

    private var dbPath: String { ChroniclePaths.databaseURL.path }

    private func openDatabase() throws -> Database {
        try ChroniclePaths.ensureSupportDirectory()
        let db = try Database(path: dbPath)
        // Apply read-time rename aliases so every query merges renamed tasks.
        try db.setAliases(AliasResolver.resolve(chains: aliasChains))
        return db
    }

    // MARK: - Range

    private func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    /// `yyyy-MM-dd` of the first day of the current (in-progress) week.
    var currentWeekStart: String {
        let today = calendar.startOfDay(for: Date())
        let start = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        return formatter().string(from: start)
    }

    /// Inclusive `yyyy-MM-dd` bounds covering the trailing `weeksWindow` weeks,
    /// aligned to Monday week starts, up to today.
    var dateBounds: (from: String, to: String) {
        let f = formatter()
        let today = calendar.startOfDay(for: Date())
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let fromDate = calendar.date(byAdding: .weekOfYear,
                                     value: -(max(1, weeksWindow) - 1),
                                     to: thisWeek) ?? thisWeek
        return (f.string(from: fromDate), f.string(from: today))
    }

    /// `yyyy-MM-dd` of the first day of the metrics week — the just-completed
    /// week the sidebar/legend tallies cover. Before `weeklyMetricsCutoff` this
    /// is the previous week; on or after it, the current week.
    var metricsWeekStart: String {
        let start = WeeklyMetrics.weekStart(for: Date(),
                                            cutoffWeekday: weeklyMetricsCutoff,
                                            calendar: calendar)
        return formatter().string(from: start)
    }

    /// Inclusive `yyyy-MM-dd` bounds of the metrics week: a full Mon–Sun span
    /// for a previous week, or Monday-to-today for the current week.
    var metricsWeekBounds: (from: String, to: String) {
        let f = formatter()
        let bounds = WeeklyMetrics.bounds(for: Date(),
                                          cutoffWeekday: weeklyMetricsCutoff,
                                          calendar: calendar)
        return (f.string(from: bounds.from), f.string(from: bounds.to))
    }

    // MARK: - Scope -> query dimension

    /// The segment dimension and the scope filter for the current selection:
    /// a task/subtask selection breaks down by Subtask; otherwise by Task.
    private var queryPlan: (dimension: SegmentDimension, scope: HierarchySelection) {
        if let taskKey = selection.taskKey {
            return (.subtask, HierarchySelection(taskKey: taskKey))
        }
        return (.task, .all)
    }

    // MARK: - Loading

    func load() {
        syncSelectionFromConfig()
        do {
            let db = try openDatabase()
            try reload(using: db)
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
        // Reflect the current authorization state and, if already granted,
        // populate the picker without prompting.
        refreshCalendarAccessState()
    }

    func reloadData() {
        do {
            let db = try openDatabase()
            try reload(using: db)
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func reload(using db: Database) throws {
        let bounds = dateBounds
        let plan = queryPlan
        if selection.taskKey == nil {
            // Top level: task-mode calendars break out into individual task
            // segments; whole-calendar-mode calendars fold into one segment each
            // (no top-N, no "Other").
            let daily = try db.activityCalendarDailySeries(from: bounds.from, to: bounds.to)
            stacks = WeeklyBucketing.bucketByCalendarSegmentMode(
                daily, calendar: calendar, wholeCalendarKeys: wholeCalendarKeys)
        } else {
            let daily = try db.segmentDailySeries(selection: plan.scope,
                                                  dimension: plan.dimension,
                                                  from: bounds.from, to: bounds.to)
            stacks = WeeklyBucketing.bucket(daily, calendar: calendar, topN: 8)
        }
        segmentStyles = Self.styles(for: stacks.segments,
                                    dimension: plan.dimension,
                                    overrides: taskColors)
        // Sidebar lists the window's activities but tallies only the metrics week.
        let week = metricsWeekBounds
        taskList = try db.taskSummaries(windowFrom: bounds.from, windowTo: bounds.to,
                                        hoursFrom: week.from, hoursTo: week.to)
        totals = try db.totals(selection: selection, from: bounds.from, to: bounds.to)
    }

    // MARK: - Derived chart data

    private var styleIndex: [String: SegmentStyle] {
        Dictionary(uniqueKeysWithValues: segmentStyles.map { ($0.key, $0) })
    }

    /// Display label for a segment key (unique per render; disambiguated in `styles`).
    func displayLabel(forSegment key: String) -> String {
        styleIndex[key]?.displayLabel ?? key
    }

    /// The domain (ordered display labels) for the color scale + legend.
    var styleDomain: [String] { segmentStyles.map(\.displayLabel) }
    var styleRange: [Color] { segmentStyles.map(\.color) }

    func color(forSegment key: String) -> Color { styleIndex[key]?.color ?? .gray }

    /// A resolved segment under the cursor, for the granular hover tooltip.
    struct HoveredSegment: Equatable {
        let week: String
        let key: String
        let label: String
        let color: Color
        let hours: Double
    }

    /// Resolves the stacked segment at `week` whose cumulative band contains the
    /// hovered hours value `hours` (as read from the chart's Y scale). Walks the
    /// week's points in `stacks.points` order (sorted by `segmentKey`) — the same
    /// per-week bottom→top band order both chart styles draw from `chartPoints`, which
    /// is how Swift Charts stacks them (first point == bottom). Returns `nil` when
    /// the value is below zero, above the week's total, or lands on a segment with
    /// no hours.
    func segment(inWeek week: String, atHours hours: Double) -> HoveredSegment? {
        guard hours >= 0 else { return nil }
        var base = 0.0
        for p in stacks.points where p.weekStart == week {
            guard p.hours > 0 else { continue }
            if hours < base + p.hours {
                return HoveredSegment(week: week, key: p.segmentKey,
                                      label: displayLabel(forSegment: p.segmentKey),
                                      color: color(forSegment: p.segmentKey),
                                      hours: p.hours)
            }
            base += p.hours
        }
        return nil
    }

    /// Short axis/tooltip label for a `yyyy-MM-dd` week start, e.g. "Jul 14".
    func weekLabelShort(_ week: String) -> String {
        guard let date = formatter().date(from: week) else { return week }
        let out = DateFormatter()
        out.calendar = calendar
        out.timeZone = calendar.timeZone
        out.locale = .current
        out.setLocalizedDateFormatFromTemplate("MMMd")
        return out.string(from: date)
    }

    func weekDate(_ week: String) -> Date { formatter().date(from: week) ?? Date() }


    /// Total recorded hours across all listed tasks for the metrics week — the
    /// denominator for each sidebar task's weekly share bar.
    var weeklyHoursTotal: Double {
        taskList.reduce(0) { $0 + $1.hours }
    }

    /// Hours in the metrics week per segment key. Derived from the already-
    /// bucketed `stacks.points`, matching the "metrics week" definition used for
    /// the sidebar tallies (`metricsWeekStart`). Segments absent from the metrics
    /// week are simply missing (callers treat that as zero).
    var metricsWeekHoursBySegment: [String: Double] {
        let week = metricsWeekStart
        var byKey: [String: Double] = [:]
        for p in stacks.points where p.weekStart == week {
            byKey[p.segmentKey, default: 0] += p.hours
        }
        return byKey
    }

    /// Total hours per week, ascending by week start.
    var weekTotals: [(weekStart: String, hours: Double)] {
        var byWeek: [String: Double] = [:]
        for p in stacks.points { byWeek[p.weekStart, default: 0] += p.hours }
        return byWeek.keys.sorted().map { ($0, byWeek[$0] ?? 0) }
    }

    /// Zero-filled series feeding the weekly chart. Unlike `stacks.points` (which is
    /// sparse — only cells with hours exist), a stacked `AreaMark` needs a value for
    /// every segment at every week in the window; otherwise a segment missing a week
    /// interpolates across the gap and distorts the stack baseline. Bars tolerate
    /// sparse data, but zero-height bars draw nothing, so this single zero-filled
    /// series drives both the area and bar styles.
    /// Points are ordered per-week by `segmentKey`, matching the bottom→top band
    /// order that `segment(inWeek:atHours:)` walks, so hover resolution stays correct
    /// (zero-hour fillers contribute nothing and are skipped by that walk).
    var chartPoints: [WeeklyStackPoint] {
        let weeks = windowWeekStarts
        guard !weeks.isEmpty, !stacks.segments.isEmpty else { return stacks.points }

        var hoursByCell: [String: Double] = [:]
        for p in stacks.points { hoursByCell["\(p.weekStart)|\(p.segmentKey)"] = p.hours }

        let segments = stacks.segments.sorted { $0.key < $1.key }
        var result: [WeeklyStackPoint] = []
        result.reserveCapacity(weeks.count * segments.count)
        for week in weeks {
            for segment in segments {
                let hours = hoursByCell["\(week)|\(segment.key)"] ?? 0
                result.append(WeeklyStackPoint(weekStart: week, segmentKey: segment.key,
                                               segmentLabel: segment.label, hours: hours))
            }
        }
        return result
    }

    // MARK: - Segment styling

    /// A distinct chart segment resolved to a unique display label and a color.
    struct SegmentStyle: Identifiable, Equatable {
        let key: String
        let displayLabel: String
        let color: Color
        var id: String { key }
    }

    /// A curated, Calendar-inspired palette (Apple Calendar's named colors, tuned
    /// for the app's dark theme, plus evenly-spaced in-between hues). Drives both
    /// auto-colors and the manual swatch picker, so assigned and hand-picked
    /// colors are drawn from the same set. The "Other" bucket is gray and is
    /// styled separately.
    static let palette: [Color] = [
        Color(hex: "#FF453A")!, // Red
        Color(hex: "#FF6B3D")!, // Vermilion
        Color(hex: "#FF9F0A")!, // Orange
        Color(hex: "#FFBF00")!, // Amber
        Color(hex: "#FFD60A")!, // Yellow
        Color(hex: "#C0E030")!, // Lime
        Color(hex: "#32D74B")!, // Green
        Color(hex: "#30E0A1")!, // Mint
        Color(hex: "#40C8E0")!, // Teal
        Color(hex: "#64D2FF")!, // Cyan
        Color(hex: "#0A84FF")!, // Blue
        Color(hex: "#5E5CE6")!, // Indigo
        Color(hex: "#7D7AFF")!, // Violet
        Color(hex: "#BF5AF2")!, // Purple
        Color(hex: "#E85AD1")!, // Magenta
        Color(hex: "#FF375F")!, // Pink
        Color(hex: "#FF6482")!, // Rose
        Color(hex: "#AC8E68")!, // Brown
        Color(hex: "#98989D")!, // Gray
    ]

    /// A stable palette color derived deterministically from a segment key, so a
    /// task keeps the same auto-color across scopes, windows, and launches
    /// (unlike Swift's per-run-randomized `Hasher`). Uses FNV-1a over the key's
    /// UTF-8 bytes to index the palette.
    static func stableColor(forKey key: String) -> Color {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return palette[Int(hash % UInt64(palette.count))]
    }

    /// The effective color for a task: its override if set, else its stable
    /// auto-color. Drives the sidebar swatch.
    func taskColor(forKey key: String) -> Color {
        if let hex = taskColors[key], let c = Color(hex: hex) { return c }
        return Self.stableColor(forKey: key)
    }

    /// Resolves segments to unique display labels + colors. The "Other" bucket is
    /// gray; every other segment uses a stable auto-color derived from its key.
    /// At the task level, a per-task override (from `overrides`) wins. A generic
    /// collision guard keeps legend labels unambiguous.
    private static func styles(for segments: [WeeklySegment],
                               dimension: SegmentDimension,
                               overrides: [String: String]) -> [SegmentStyle] {
        var used: Set<String> = []
        return segments.map { segment in
            let color: Color
            if segment.isOther {
                color = .gray
            } else if segment.isCalendarBucket {
                color = Color(hex: segment.colorHex) ?? .gray
            } else if dimension == .task, let hex = overrides[segment.key],
                      let override = Color(hex: hex) {
                color = override
            } else {
                color = stableColor(forKey: segment.key)
            }

            var unique = segment.label
            var n = 2
            while used.contains(unique) { unique = "\(segment.label) (\(n))"; n += 1 }
            used.insert(unique)

            return SegmentStyle(key: segment.key, displayLabel: unique, color: color)
        }
    }

    /// Assigns (or clears, when `color` is nil) a task's color override, persists
    /// it to config, and recomputes segment styles. Color is display-only, so
    /// this never re-extracts from Calendar.
    func setTaskColor(_ key: String, _ color: Color?) {
        do {
            var config = try ChronicleConfig.load()
            if let color, let hex = color.hexString {
                config.taskColors[key] = hex
            } else {
                config.taskColors.removeValue(forKey: key)
            }
            try config.save()
            taskColors = config.taskColors
            // Recompute styles for the current scope so the chart/legend update.
            segmentStyles = Self.styles(for: stacks.segments,
                                        dimension: queryPlan.dimension,
                                        overrides: taskColors)
            objectWillChange.send()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Sets whether a calendar renders as a single whole-calendar segment (vs.
    /// the default per-task breakdown), persists it, and re-buckets the current
    /// scope. Segmentation is display-only, so this never re-extracts from
    /// Calendar.
    func setCalendarSegmentMode(_ info: CalendarInfo, wholeCalendar: Bool) {
        do {
            var config = try ChronicleConfig.load()
            let key = Self.normalizeTitle(info.title)
            config.wholeCalendarSegments.removeAll { Self.normalizeTitle($0) == key }
            if wholeCalendar {
                config.wholeCalendarSegments.append(info.title)
            }
            try config.save()
            wholeCalendarTitleKeys = Set(config.wholeCalendarSegments.map(Self.normalizeTitle))
            wholeCalendarKeys = Set(config.wholeCalendarSegments.map { TitleParser.normalize($0).key })
            reloadData()
            objectWillChange.send()
        } catch {
            errorMessage = "\(error)"
        }
    }

    // MARK: - Rename aliases

    /// Normalized comparison key for a raw title, matching how the extractor and
    /// queries key tasks/subtasks. Used to detect duplicates and locate the
    /// chain a new rename should extend.
    private static func titleKey(_ raw: String) -> String? {
        guard let parsed = TitleParser.parse(raw) else { return nil }
        return "\(parsed.task.key)\u{1F}\(parsed.subtask?.key ?? "")"
    }

    /// Records that `from` was renamed to `to`. If an existing chain's canonical
    /// (last) title matches `from`, `to` is appended to it — this is how a chain
    /// grows across successive renames; otherwise a new two-entry chain is
    /// created. Persists to config and reloads (read-time, no re-extraction).
    /// No-op when either title is unparseable or the pair already exists.
    func addRename(from: String, to: String) {
        guard let fromKey = Self.titleKey(from),
              let toKey = Self.titleKey(to),
              fromKey != toKey else { return }
        do {
            var config = try ChronicleConfig.load()
            if let idx = config.aliasChains.firstIndex(where: {
                guard let last = $0.last else { return false }
                return Self.titleKey(last) == fromKey
            }) {
                // Avoid a no-op if `to` is already the chain's canonical.
                if Self.titleKey(config.aliasChains[idx].last ?? "") != toKey {
                    config.aliasChains[idx].append(to)
                }
            } else {
                config.aliasChains.append([from, to])
            }
            try saveAliasChains(config)
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Removes the entire rename chain at `index`.
    func removeAliasChain(at index: Int) {
        do {
            var config = try ChronicleConfig.load()
            guard config.aliasChains.indices.contains(index) else { return }
            config.aliasChains.remove(at: index)
            try saveAliasChains(config)
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func saveAliasChains(_ config: ChronicleConfig) throws {
        try config.save()
        aliasChains = config.aliasChains
        reloadData()
        objectWillChange.send()
    }

    // MARK: - Selection

    /// A human-readable path for the current selection, derived from labels.
    var currentTitle: String {
        switch selection.taskKey {
        case .none:
            return "All Tasks"
        case .some(let taskKey):
            let task = taskList.first { $0.key == taskKey }
            guard let subKey = selection.subtaskKey else {
                return task?.label ?? "Task"
            }
            let sub = task?.subtasks.first { $0.key == subKey }
            return [task?.label, sub?.label].compactMap { $0 }.joined(separator: " / ")
        }
    }

    func select(_ selection: HierarchySelection, nodeID: String) {
        self.selection = selection
        self.selectedNodeID = nodeID
        reloadData()
    }

    // MARK: - Keyboard navigation

    /// Ordered node IDs the ⌘←/⌘→ shortcuts step through: the "All Tasks" home
    /// row followed by each top-level activity (subtasks are excluded).
    private var navigableNodeIDs: [String] {
        ["all"] + taskList.map { "task:\($0.key)" }
    }

    /// Selects the "All Tasks" home scope (⌘0 / ⌘⇧H).
    func selectHome() {
        select(.all, nodeID: "all")
    }

    /// Expands or collapses the navigation sidebar (⌘\ / ⌘B).
    func toggleSidebar() {
        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
    }

    /// Selects the Nth top-level activity (1-based, matching ⌘1…⌘9). No-op when
    /// fewer than `oneBasedIndex` activities exist.
    func selectActivity(_ oneBasedIndex: Int) {
        let idx = oneBasedIndex - 1
        guard taskList.indices.contains(idx) else { return }
        let task = taskList[idx]
        select(HierarchySelection(taskKey: task.key), nodeID: "task:\(task.key)")
    }

    /// Moves the selection ±1 within `navigableNodeIDs`, clamped at the ends. If
    /// the current selection isn't a navigable row (e.g. a subtask is selected),
    /// it's treated as its parent activity so prev/next still behave intuitively.
    func navigateSibling(_ offset: Int) {
        let ids = navigableNodeIDs
        guard !ids.isEmpty else { return }

        let currentID: String
        if selectedNodeID.hasPrefix("sub:"), let taskKey = selection.taskKey {
            currentID = "task:\(taskKey)"
        } else {
            currentID = selectedNodeID
        }

        let current = ids.firstIndex(of: currentID) ?? 0
        let target = min(max(current + offset, 0), ids.count - 1)
        guard target != current else { return }

        if target == 0 {
            selectHome()
        } else {
            selectActivity(target) // target maps 1-based onto taskList
        }
    }

    /// True when the chart segments each bar by activity (Task), i.e. the top
    /// level or a calendar scope — as opposed to a subtask breakdown.
    var isTaskLevel: Bool { selection.taskKey == nil }

    /// Drills into an activity segment so the chart re-stacks it by subtask.
    /// No-op for the "Other" bucket, per-calendar buckets, or when already at
    /// subtask level. The segment key is the (calendar-agnostic) task key.
    func drillInto(segmentKey key: String) {
        guard isTaskLevel,
              key != WeeklyBucketing.otherKey,
              !WeeklyBucketing.isCalendarBucketKey(key) else { return }
        select(HierarchySelection(taskKey: key), nodeID: "task:\(key)")
    }

    /// Moves the scope up one level (subtask → task → all).
    func drillUp() {
        if selection.subtaskKey != nil, let taskKey = selection.taskKey {
            select(HierarchySelection(taskKey: taskKey), nodeID: "task:\(taskKey)")
        } else if selection.taskKey != nil {
            select(.all, nodeID: "all")
        }
    }

    /// Every week start in the current window (ascending), so the X axis shows
    /// all `weeksWindow` weeks even when some have no data.
    var windowWeekStarts: [String] {
        let f = formatter()
        guard let start = f.date(from: dateBounds.from),
              let end = f.date(from: currentWeekStart) else { return [] }
        var result: [String] = []
        var day = start
        while day <= end {
            result.append(f.string(from: day))
            day = calendar.date(byAdding: .weekOfYear, value: 1, to: day) ?? end.addingTimeInterval(1)
            if result.count > 60 { break }
        }
        return result
    }

    /// `windowWeekStarts` as `Date`s, for the chart's continuous X axis.
    var windowWeekDates: [Date] {
        let f = formatter()
        return windowWeekStarts.compactMap { f.date(from: $0) }
    }

    /// The continuous X-axis domain: first week start through last. A continuous
    /// (vs categorical) domain places the endpoints exactly on the plot edges, so
    /// the stacked area/bars run edge-to-edge with no side padding.
    var windowDateDomain: ClosedRange<Date> {
        let dates = windowWeekDates
        guard let lo = dates.first, let hi = dates.last, lo < hi else {
            let now = Date()
            return now...now.addingTimeInterval(1)
        }
        return lo...hi
    }

    /// Short axis label for a week-start `Date`, e.g. "Jul 14".
    func weekLabelShort(date: Date) -> String {
        weekLabelShort(formatter().string(from: date))
    }

    /// Whether a week-start `Date` is the current (in-progress) week.
    func isCurrentWeek(_ date: Date) -> Bool {
        formatter().string(from: date) == currentWeekStart
    }

    /// Snaps a hovered X-axis `Date` to the nearest week-start key, for resolving
    /// which week's stack the cursor is over on the continuous axis.
    func nearestWeek(to date: Date) -> String? {
        let dates = windowWeekDates
        guard !dates.isEmpty else { return nil }
        let nearest = dates.min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) }
        return nearest.map { formatter().string(from: $0) }
    }

    func setWeeksWindow(_ weeks: Int) {
        weeksWindow = weeks
        reloadData()
    }

    // MARK: - Calendar picker

    private static func normalizeTitle(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func syncSelectionFromConfig() {
        if let config = try? ChronicleConfig.load() {
            allowedTitleKeys = Set(config.calendarAllowlist.map(Self.normalizeTitle))
            subtractiveTitleKeys = Set(config.subtractiveCalendars.map(Self.normalizeTitle))
            wholeCalendarTitleKeys = Set(config.wholeCalendarSegments.map(Self.normalizeTitle))
            wholeCalendarKeys = Set(config.wholeCalendarSegments.map { TitleParser.normalize($0).key })
            taskColors = config.taskColors
            aliasChains = config.aliasChains
            weeklyMetricsCutoff = config.weeklyMetricsCutoff
        }
    }

    func isCalendarSelected(_ info: CalendarInfo) -> Bool {
        allowedTitleKeys.contains(Self.normalizeTitle(info.title))
    }

    /// `availableCalendars` reordered so selected (allowlisted) calendars come
    /// first. `availableCalendars` is already sorted alphabetically and this is a
    /// stable partition, so A→Z order is preserved within each group. Re-sorts
    /// live when a calendar is toggled (`persist` fires `objectWillChange`).
    var sortedAvailableCalendars: [CalendarInfo] {
        let selected = availableCalendars.filter { isCalendarSelected($0) }
        let unselected = availableCalendars.filter { !isCalendarSelected($0) }
        return selected + unselected
    }

    func isCalendarSubtractive(_ info: CalendarInfo) -> Bool {
        subtractiveTitleKeys.contains(Self.normalizeTitle(info.title))
    }

    /// Whether a calendar renders as one whole-calendar segment at the top level
    /// (as opposed to the default per-task breakdown).
    func isCalendarWholeSegment(_ info: CalendarInfo) -> Bool {
        wholeCalendarTitleKeys.contains(Self.normalizeTitle(info.title))
    }

    var selectedCalendarCount: Int { allowedTitleKeys.count }

    /// Called when the app becomes active (e.g. returning from System Settings)
    /// and on launch. Re-reads the live authorization status so the picker
    /// updates itself after the user grants access outside the app.
    func refreshCalendarAccessState() {
        switch CalendarExtractor.authorizationStatus {
        case .fullAccess:
            calendarAccessDenied = false
            // Populate (or re-populate) the picker without prompting.
            if availableCalendars.isEmpty { loadCalendars() }
        case .denied, .restricted:
            // Keep any calendars we already loaded, but surface the denial so
            // the button can route the user to System Settings.
            if !hasCalendarAccess { calendarAccessDenied = true }
        default: // .notDetermined
            calendarAccessDenied = false
        }
    }

    /// Backs the "Grant Calendar Access" button. `requestFullAccessToEvents()`
    /// only shows the system prompt when the status is `.notDetermined`; once a
    /// user has denied access it returns `false` without any UI. In that case we
    /// send them straight to the Calendars pane in System Settings instead of
    /// silently failing.
    func requestCalendarAccess() {
        switch CalendarExtractor.authorizationStatus {
        case .denied, .restricted:
            openCalendarSettings()
        default: // .notDetermined prompts; .fullAccess just loads.
            loadCalendars()
        }
    }

    /// Opens System Settings › Privacy & Security › Calendars.
    func openCalendarSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        if let url { NSWorkspace.shared.open(url) }
    }

    /// Requests Calendar access (prompting if needed) and loads the calendar
    /// list for the picker. Safe to call repeatedly.
    func loadCalendars() {
        guard !isLoadingCalendars else { return }
        isLoadingCalendars = true
        Task {
            do {
                let extractor = CalendarExtractor()
                try await extractor.requestAccess()
                let cals = extractor.availableCalendars()
                await MainActor.run {
                    self.availableCalendars = cals
                    self.hasCalendarAccess = true
                    self.calendarAccessDenied = false
                    self.isLoadingCalendars = false
                    self.errorMessage = nil
                }
            } catch {
                await MainActor.run {
                    self.isLoadingCalendars = false
                    self.hasCalendarAccess = false
                    self.calendarAccessDenied =
                        CalendarExtractor.authorizationStatus != .notDetermined
                    self.errorMessage = "\(error)"
                }
            }
        }
    }

    /// Includes/excludes a calendar, persists the allowlist, and re-extracts.
    /// Removing a calendar also clears any subtractive designation.
    func setCalendar(_ info: CalendarInfo, included: Bool) {
        do {
            var config = try ChronicleConfig.load()
            let key = Self.normalizeTitle(info.title)
            config.calendarAllowlist.removeAll { Self.normalizeTitle($0) == key }
            if included {
                config.calendarAllowlist.append(info.title)
            } else {
                config.subtractiveCalendars.removeAll { Self.normalizeTitle($0) == key }
            }
            try persist(config)
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Marks a calendar subtractive (or not). Marking subtractive auto-includes
    /// it, since a subtractive calendar's own time is still counted.
    func setSubtractive(_ info: CalendarInfo, subtractive: Bool) {
        do {
            var config = try ChronicleConfig.load()
            let key = Self.normalizeTitle(info.title)
            config.subtractiveCalendars.removeAll { Self.normalizeTitle($0) == key }
            if subtractive {
                config.subtractiveCalendars.append(info.title)
                if !config.calendarAllowlist.contains(where: { Self.normalizeTitle($0) == key }) {
                    config.calendarAllowlist.append(info.title)
                }
            }
            try persist(config)
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Saves the config, refreshes local mirrors, and re-extracts.
    private func persist(_ config: ChronicleConfig) throws {
        try config.save()
        allowedTitleKeys = Set(config.calendarAllowlist.map(Self.normalizeTitle))
        subtractiveTitleKeys = Set(config.subtractiveCalendars.map(Self.normalizeTitle))
        objectWillChange.send()
        refresh()
    }

    // MARK: - Refresh (extracts from Calendar in-process)

    /// Requests Calendar access (showing the system prompt if needed) and
    /// rebuilds the rolling window directly from EventKit. Running in-process
    /// means macOS attributes the permission request to Chronicle itself, so
    /// the prompt appears and the app registers under Privacy > Calendars.
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil
        Task {
            do {
                let config = try ChronicleConfig.load()
                _ = try ChroniclePaths.ensureSupportDirectory()
                let extractor = CalendarExtractor()
                try await extractor.requestAccess()
                let summary = try extractor.extract(config: config, databasePath: dbPath)
                await MainActor.run {
                    self.isRefreshing = false
                    self.load()
                    if summary.includedCalendars.isEmpty {
                        self.errorMessage = "No calendars selected. Click the "
                            + "Calendars button in the toolbar to choose which "
                            + "calendars to include."
                    }
                }
            } catch {
                await MainActor.run {
                    self.isRefreshing = false
                    self.errorMessage = "\(error)"
                }
            }
        }
    }
}

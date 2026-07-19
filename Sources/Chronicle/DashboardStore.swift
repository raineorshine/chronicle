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
    @Published var calendars: [CalendarNode] = []
    @Published var selection: HierarchySelection = .all
    @Published var selectedNodeID: String = "all"

    /// Number of trailing weeks shown on the X axis (includes the current,
    /// in-progress week). One of `allowedWeekWindows`.
    @Published var weeksWindow: Int = 8

    /// Bucketed weekly stacks for the current scope + window.
    @Published var stacks: WeeklyStacks = .empty
    /// Segment styles (display label + color) in stacking / legend order.
    @Published var segmentStyles: [SegmentStyle] = []
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
        return try Database(path: dbPath)
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

    // MARK: - Scope -> query dimension

    /// The segment dimension and the scope filter for the current selection:
    /// a task/subtask selection breaks down by Subtask; otherwise by Task.
    private var queryPlan: (dimension: SegmentDimension, scope: HierarchySelection) {
        if selection.taskKey != nil {
            return (.subtask, HierarchySelection(calendarKey: selection.calendarKey,
                                                 taskKey: selection.taskKey))
        }
        return (.task, HierarchySelection(calendarKey: selection.calendarKey))
    }

    // MARK: - Loading

    func load() {
        syncSelectionFromConfig()
        do {
            let db = try openDatabase()
            calendars = try db.hierarchy()
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
        let daily = try db.segmentDailySeries(selection: plan.scope,
                                              dimension: plan.dimension,
                                              from: bounds.from, to: bounds.to)
        stacks = WeeklyBucketing.bucket(daily, calendar: calendar, topN: 8)
        segmentStyles = Self.styles(for: stacks.segments, calendars: calendars)
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

    /// A week's segments as (label, color, hours), heaviest first — for tooltips.
    func segments(inWeek week: String) -> [(label: String, color: Color, hours: Double)] {
        stacks.points
            .filter { $0.weekStart == week }
            .map { (displayLabel(forSegment: $0.segmentKey),
                    color(forSegment: $0.segmentKey), $0.hours) }
            .sorted { $0.hours > $1.hours }
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


    /// Total hours per week, ascending by week start.
    var weekTotals: [(weekStart: String, hours: Double)] {
        var byWeek: [String: Double] = [:]
        for p in stacks.points { byWeek[p.weekStart, default: 0] += p.hours }
        return byWeek.keys.sorted().map { ($0, byWeek[$0] ?? 0) }
    }

    /// Hours logged in the most recent week and the delta versus the prior week.
    var latestWeek: (hours: Double, delta: Double?) {
        let totals = weekTotals
        guard let last = totals.last else { return (0, nil) }
        let prior = totals.count >= 2 ? totals[totals.count - 2].hours : nil
        return (last.hours, prior.map { last.hours - $0 })
    }

    // MARK: - Segment styling

    /// A distinct chart segment resolved to a unique display label and a color.
    struct SegmentStyle: Identifiable, Equatable {
        let key: String
        let displayLabel: String
        let color: Color
        var id: String { key }
    }

    /// A categorical palette for activity/subtask segments (Other -> gray).
    private static let palette: [Color] = [
        Color(hex: "#4E79A7")!, Color(hex: "#F28E2B")!, Color(hex: "#59A14F")!,
        Color(hex: "#E15759")!, Color(hex: "#B07AA1")!, Color(hex: "#76B7B2")!,
        Color(hex: "#EDC948")!, Color(hex: "#FF9DA7")!, Color(hex: "#9C755F")!,
        Color(hex: "#BAB0AC")!
    ]

    /// Resolves segments to unique display labels + palette colors. Duplicate
    /// labels (e.g. same task name in two calendars) are disambiguated with the
    /// calendar name so the legend and color scale stay unambiguous.
    private static func styles(for segments: [WeeklySegment],
                               calendars: [CalendarNode]) -> [SegmentStyle] {
        let calendarLabel = Dictionary(uniqueKeysWithValues:
            calendars.map { ($0.key, $0.label) })

        var labelCounts: [String: Int] = [:]
        for s in segments where !s.isOther { labelCounts[s.label, default: 0] += 1 }

        var used: Set<String> = []
        var paletteIndex = 0
        return segments.map { segment in
            let color: Color
            if segment.isOther {
                color = .gray
            } else {
                color = palette[paletteIndex % palette.count]
                paletteIndex += 1
            }

            var label = segment.label
            if !segment.isOther, (labelCounts[segment.label] ?? 0) > 1 {
                let calKey = segment.key.split(separator: "\u{1F}").first.map(String.init) ?? ""
                if let cal = calendarLabel[calKey] { label = "\(segment.label) · \(cal)" }
            }
            // Guard against any remaining collisions.
            var unique = label
            var n = 2
            while used.contains(unique) { unique = "\(label) (\(n))"; n += 1 }
            used.insert(unique)

            return SegmentStyle(key: segment.key, displayLabel: unique, color: color)
        }
    }

    // MARK: - Selection

    /// A human-readable path for the current selection, derived from labels.
    var currentTitle: String {
        let parts = selectedNodeID.split(separator: ":").map(String.init)
        guard let kind = parts.first else { return "All Calendars" }
        switch kind {
        case "cal" where parts.count >= 2:
            return calendars.first { $0.key == parts[1] }?.label ?? "Calendar"
        case "task" where parts.count >= 3:
            let cal = calendars.first { $0.key == parts[1] }
            let task = cal?.tasks.first { $0.key == parts[2] }
            return [cal?.label, task?.label].compactMap { $0 }.joined(separator: " / ")
        case "sub" where parts.count >= 4:
            let cal = calendars.first { $0.key == parts[1] }
            let task = cal?.tasks.first { $0.key == parts[2] }
            let sub = task?.subtasks.first { $0.key == parts[3] }
            return [cal?.label, task?.label, sub?.label].compactMap { $0 }.joined(separator: " / ")
        default:
            return "All Calendars"
        }
    }

    func select(_ selection: HierarchySelection, nodeID: String) {
        self.selection = selection
        self.selectedNodeID = nodeID
        reloadData()
    }

    /// True when the chart segments each bar by activity (Task), i.e. the top
    /// level or a calendar scope — as opposed to a subtask breakdown.
    var isTaskLevel: Bool { selection.taskKey == nil }

    /// Drills into an activity segment so the chart re-stacks it by subtask.
    /// No-op for the "Other" bucket or when already at subtask level.
    func drillInto(segmentKey key: String) {
        guard isTaskLevel, key != WeeklyBucketing.otherKey else { return }
        let parts = key.split(separator: "\u{1F}").map(String.init)
        guard parts.count == 2 else { return }
        select(HierarchySelection(calendarKey: parts[0], taskKey: parts[1]),
               nodeID: "task:\(parts[0]):\(parts[1])")
    }

    /// Moves the scope up one level (subtask → task → calendar → all).
    func drillUp() {
        let parts = selectedNodeID.split(separator: ":").map(String.init)
        switch parts.first {
        case "sub" where parts.count >= 3:
            select(HierarchySelection(calendarKey: parts[1], taskKey: parts[2]),
                   nodeID: "task:\(parts[1]):\(parts[2])")
        case "task" where parts.count >= 2:
            select(HierarchySelection(calendarKey: parts[1]), nodeID: "cal:\(parts[1])")
        case "cal":
            select(.all, nodeID: "all")
        default:
            break
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
        }
    }

    func isCalendarSelected(_ info: CalendarInfo) -> Bool {
        allowedTitleKeys.contains(Self.normalizeTitle(info.title))
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
    func setCalendar(_ info: CalendarInfo, included: Bool) {
        do {
            var config = try ChronicleConfig.load()
            let key = Self.normalizeTitle(info.title)
            config.calendarAllowlist.removeAll { Self.normalizeTitle($0) == key }
            if included { config.calendarAllowlist.append(info.title) }
            try config.save()
            allowedTitleKeys = Set(config.calendarAllowlist.map(Self.normalizeTitle))
            objectWillChange.send()
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
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

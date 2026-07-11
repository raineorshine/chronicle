import Foundation
import SwiftUI
import ChronicleCore

/// Preset time ranges for the dashboard. All are trailing windows ending today,
/// except `.custom`, which uses explicit dates.
enum RangePreset: String, CaseIterable, Identifiable {
    case week, month, year, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .week: return "Week"
        case .month: return "Month"
        case .year: return "Year"
        case .custom: return "Custom"
        }
    }
}

/// Observable state backing the dashboard: hierarchy tree, current selection,
/// range, and the derived daily series + totals read from SQLite.
@MainActor
final class DashboardStore: ObservableObject {
    @Published var calendars: [CalendarNode] = []
    @Published var selection: HierarchySelection = .all
    @Published var selectedNodeID: String = "all"

    @Published var preset: RangePreset = .week
    @Published var customFrom: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    @Published var customTo: Date = Date()

    @Published var points: [DailyPoint] = []
    @Published var totals: RangeTotals = .zero
    @Published var errorMessage: String?
    @Published var isRefreshing = false

    // MARK: - Calendar picker state

    /// All event calendars (with colors) discovered from EventKit.
    @Published var availableCalendars: [CalendarInfo] = []
    /// Whether Calendar access has been granted.
    @Published var hasCalendarAccess = false
    /// True while calendars are being loaded / access requested.
    @Published var isLoadingCalendars = false

    /// Normalized titles of calendars currently included (mirrors config allowlist).
    private var allowedTitleKeys: Set<String> = []

    private let calendar = Calendar.current

    private var dbPath: String { ChroniclePaths.databaseURL.path }

    private func openDatabase() throws -> Database {
        try ChroniclePaths.ensureSupportDirectory()
        return try Database(path: dbPath)
    }

    // MARK: - Range

    /// Inclusive `yyyy-MM-dd` bounds for the current range selection.
    var dateBounds: (from: String, to: String) {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"

        let today = calendar.startOfDay(for: Date())
        let fromDate: Date
        let toDate: Date
        switch preset {
        case .week:
            fromDate = calendar.date(byAdding: .day, value: -6, to: today)!
            toDate = today
        case .month:
            fromDate = calendar.date(byAdding: .day, value: -29, to: today)!
            toDate = today
        case .year:
            fromDate = calendar.date(byAdding: .day, value: -364, to: today)!
            toDate = today
        case .custom:
            fromDate = min(customFrom, customTo)
            toDate = max(customFrom, customTo)
        }
        return (f.string(from: fromDate), f.string(from: toDate))
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
        // If access was already granted, populate the picker without prompting.
        if CalendarExtractor.authorizationStatus == .fullAccess {
            loadCalendars()
        }
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
        let series = try db.dailySeries(selection: selection, from: bounds.from, to: bounds.to)
        points = fill(series: series, from: bounds.from, to: bounds.to)
        totals = try db.totals(selection: selection, from: bounds.from, to: bounds.to)
    }

    /// Fills missing days with zero so the chart shows a continuous axis.
    private func fill(series: [DailyPoint], from: String, to: String) -> [DailyPoint] {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let start = f.date(from: from), let end = f.date(from: to), start <= end else {
            return series
        }
        let byDate = Dictionary(uniqueKeysWithValues: series.map { ($0.date, $0) })
        var result: [DailyPoint] = []
        var day = start
        while day <= end {
            let key = f.string(from: day)
            result.append(byDate[key] ?? DailyPoint(date: key, hours: 0, occurrences: 0))
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return result
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
                    self.isLoadingCalendars = false
                    self.errorMessage = nil
                }
            } catch {
                await MainActor.run {
                    self.isLoadingCalendars = false
                    self.hasCalendarAccess = false
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
    /// the prompt appears and the app registers under Privacy › Calendars.
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

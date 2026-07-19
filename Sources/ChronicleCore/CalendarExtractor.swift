import Foundation
import EventKit
import CoreGraphics

/// Result of an extraction run, for logging / UI feedback.
public struct ExtractionSummary {
    public let availableCalendars: [String]
    public let includedCalendars: [String]
    public let rowCount: Int
    public let firstDate: String
    public let lastDate: String
}

public enum ExtractionError: Error, CustomStringConvertible {
    case accessDenied

    public var description: String {
        switch self {
        case .accessDenied:
            return "Calendar access was denied. Grant access in "
                + "System Settings › Privacy & Security › Calendars."
        }
    }
}

/// Reads events from EventKit and rebuilds the rolling window of `daily_time`
/// aggregates. Shared by the CLI extractor and the app's Refresh button so the
/// responsible process (whichever has the usage description) drives the request.
public final class CalendarExtractor {
    private let store: EKEventStore

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    public static var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// Triggers the system permission prompt (or resolves an existing grant).
    /// Throws `ExtractionError.accessDenied` if not granted.
    @discardableResult
    public func requestAccess() async throws -> Bool {
        let granted = try await store.requestFullAccessToEvents()
        guard granted else { throw ExtractionError.accessDenied }
        return granted
    }

    public var availableCalendarTitles: [String] {
        store.calendars(for: .event).map(\.title).sorted()
    }

    /// Lists all event calendars with their display color, for an in-app picker.
    public func availableCalendars() -> [CalendarInfo] {
        store.calendars(for: .event)
            .map { CalendarInfo(identifier: $0.calendarIdentifier,
                                title: $0.title,
                                colorHex: Self.hexString(from: $0.cgColor)) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Fetches events for the rolling window from allowlisted calendars,
    /// aggregates them, and rewrites the window in the database.
    /// Requires calendar access to already be granted.
    @discardableResult
    public func extract(config: ChronicleConfig,
                        databasePath: String,
                        calendar: Calendar = .current,
                        now: Date = Date()) throws -> ExtractionSummary {
        let window = ExtractionWindow.rolling(pastDays: config.windowPastDays,
                                              futureDays: config.windowFutureDays,
                                              now: now,
                                              calendar: calendar)
        let bounds = window.dateBounds(calendar: calendar)

        let all = store.calendars(for: .event)
        let allow = Set(config.calendarAllowlist.map(Self.normalize))
        let subtractive = Set(config.subtractiveCalendars.map(Self.normalize))
        // Subtractive calendars are always extracted so they can subtract (and
        // their own time counts), even when not explicitly in the allowlist.
        let included = all.filter {
            let key = Self.normalize($0.title)
            return allow.contains(key) || subtractive.contains(key)
        }

        var inputs: [EventInput] = []
        if !included.isEmpty {
            let predicate = store.predicateForEvents(withStart: window.start,
                                                     end: window.end,
                                                     calendars: included)
            for event in store.events(matching: predicate) {
                if event.isAllDay { continue }
                guard let start = event.startDate, let end = event.endDate else { continue }
                guard let parsed = TitleParser.parse(event.title ?? "",
                                                     separator: config.subtaskSeparator) else { continue }
                let isSubtractive = subtractive.contains(Self.normalize(event.calendar.title))
                inputs.append(EventInput(calendar: TitleParser.normalize(event.calendar.title),
                                         title: parsed,
                                         start: start,
                                         end: end,
                                         isAllDay: false,
                                         calendarColor: Self.hexString(from: event.calendar.cgColor),
                                         isSubtractive: isSubtractive))
            }
        }

        let rows = DateAggregator(calendar: calendar).aggregate(inputs, window: window)
        let db = try Database(path: databasePath)
        try db.replaceWindow(rows: rows, firstDate: bounds.first, lastDate: bounds.last)

        return ExtractionSummary(availableCalendars: all.map(\.title).sorted(),
                                 includedCalendars: included.map(\.title).sorted(),
                                 rowCount: rows.count,
                                 firstDate: bounds.first,
                                 lastDate: bounds.last)
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Converts a calendar's `CGColor` to an `#RRGGBB` string for display.
    private static func hexString(from cgColor: CGColor?) -> String? {
        guard let cgColor else { return nil }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)
        let converted = srgb.flatMap {
            cgColor.converted(to: $0, intent: .defaultIntent, options: nil)
        } ?? cgColor
        guard let comps = converted.components, !comps.isEmpty else { return nil }

        let r: CGFloat, g: CGFloat, b: CGFloat
        if comps.count >= 3 {
            r = comps[0]; g = comps[1]; b = comps[2]
        } else {
            // Grayscale: single luminance component.
            r = comps[0]; g = comps[0]; b = comps[0]
        }
        func channel(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(r), channel(g), channel(b))
    }
}

/// A calendar available to include in metrics, surfaced to the in-app picker.
public struct CalendarInfo: Identifiable, Hashable, Sendable {
    public let identifier: String
    public let title: String
    public let colorHex: String?

    public var id: String { identifier }

    public init(identifier: String, title: String, colorHex: String?) {
        self.identifier = identifier
        self.title = title
        self.colorHex = colorHex
    }
}

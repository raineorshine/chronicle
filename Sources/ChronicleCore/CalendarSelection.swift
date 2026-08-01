import Foundation
import EventKit

/// Which of the user's calendars Chronicle tracks. Every path that touches
/// EventKit — extraction, replacement, the schedule preview — resolves the set
/// through here, so they can never disagree about what counts.
public enum CalendarSelection {

    /// The calendars in `all` that the config's allowlist includes, returned in
    /// the allowlist's priority order (highest priority first). Allowlist entries
    /// naming a calendar the user no longer has are skipped.
    public static func included(from all: [EKCalendar],
                                config: ChronicleConfig) -> [EKCalendar] {
        let byKey = Dictionary(all.map { (normalize($0.title), $0) },
                               uniquingKeysWith: { first, _ in first })
        return config.calendarAllowlist.compactMap { byKey[normalize($0)] }
    }

    /// Priority rank per normalized calendar title: `0` for the first allowlist
    /// entry, `1` for the next, and so on. Titles outside the allowlist are
    /// absent — callers rank those `Int.max`, which subtracts from nothing.
    public static func ranks(config: ChronicleConfig) -> [String: Int] {
        var ranks: [String: Int] = [:]
        for title in config.calendarAllowlist {
            let key = normalize(title)
            if ranks[key] == nil { ranks[key] = ranks.count }
        }
        return ranks
    }

    /// Comparison form for a calendar title: trimmed and lowercased.
    public static func normalize(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

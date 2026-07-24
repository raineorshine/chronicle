import Foundation
import EventKit

/// Which of the user's calendars Chronicle tracks. Every path that touches
/// EventKit — extraction, replacement, the schedule preview — resolves the set
/// through here, so they can never disagree about what counts.
public enum CalendarSelection {

    /// The calendars in `all` that the config includes: the allowlist plus every
    /// subtractive calendar. Subtractive calendars are always included so they can
    /// subtract (and their own time counts), even when not explicitly allowlisted.
    public static func included(from all: [EKCalendar],
                                config: ChronicleConfig) -> [EKCalendar] {
        let allow = Set(config.calendarAllowlist.map(normalize))
        let subtractive = Set(config.subtractiveCalendars.map(normalize))
        return all.filter {
            let key = normalize($0.title)
            return allow.contains(key) || subtractive.contains(key)
        }
    }

    /// The included calendars that hold *planned* time — everything `included`
    /// returns, minus the subtractive ones. A subtractive calendar records what
    /// actually happened rather than what is scheduled, so a view answering "when
    /// does this happen" would otherwise show an activity twice on any day it was
    /// both planned and logged.
    public static func planned(from all: [EKCalendar],
                               config: ChronicleConfig) -> [EKCalendar] {
        let subtractive = Set(config.subtractiveCalendars.map(normalize))
        return included(from: all, config: config)
            .filter { !subtractive.contains(normalize($0.title)) }
    }

    /// Comparison form for a calendar title: trimmed and lowercased.
    public static func normalize(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

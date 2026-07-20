import Foundation

/// Pure date logic for the "weekly metrics cutoff": which week the sidebar and
/// legend tallies should cover on any given day.
///
/// The cutoff is a weekday (Foundation numbering: 1 = Sunday … 7 = Saturday).
/// Before the cutoff weekday, the just-completed work week isn't rolled over
/// yet, so the tallies cover the **previous** full week (Mon–Sun). On or after
/// the cutoff weekday, they cover the **current** week (Mon–today).
///
/// With the default cutoff of Friday (`6`): Mon–Thu show the previous week,
/// Fri–Sun show the current week. Week boundaries follow `calendar.firstWeekday`
/// (Monday in this app). Kept free of SwiftUI so it is unit-testable.
public enum WeeklyMetrics {
    /// The start date (aligned to `calendar.firstWeekday`) of the metrics week
    /// for `today`, given `cutoffWeekday` (Foundation numbering, 1 = Sunday).
    public static func weekStart(for today: Date,
                                 cutoffWeekday: Int,
                                 calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: today)
        let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? day
        if firstWeekdayIndex(for: day, calendar: calendar) < cutoffIndex(cutoffWeekday, calendar: calendar) {
            return calendar.date(byAdding: .weekOfYear, value: -1, to: currentWeekStart) ?? currentWeekStart
        }
        return currentWeekStart
    }

    /// Inclusive bounds of the metrics week: `from` is the week start, `to` is
    /// the earlier of `today` and the week's last day (start + 6 days). So the
    /// previous week resolves to a full Mon–Sun span while the current week is
    /// capped at today.
    public static func bounds(for today: Date,
                              cutoffWeekday: Int,
                              calendar: Calendar) -> (from: Date, to: Date) {
        let day = calendar.startOfDay(for: today)
        let start = weekStart(for: day, cutoffWeekday: cutoffWeekday, calendar: calendar)
        let weekEnd = calendar.date(byAdding: .day, value: 6, to: start) ?? start
        return (start, min(day, weekEnd))
    }

    /// 0-based index of `date`'s weekday within the week, honoring
    /// `calendar.firstWeekday` (e.g. Monday-first → Mon = 0 … Sun = 6).
    private static func firstWeekdayIndex(for date: Date, calendar: Calendar) -> Int {
        index(of: calendar.component(.weekday, from: date), calendar: calendar)
    }

    /// 0-based, first-weekday-relative index for an arbitrary Foundation weekday.
    private static func cutoffIndex(_ weekday: Int, calendar: Calendar) -> Int {
        index(of: weekday, calendar: calendar)
    }

    private static func index(of weekday: Int, calendar: Calendar) -> Int {
        // Foundation weekdays are 1...7; normalize relative to firstWeekday.
        ((weekday - calendar.firstWeekday) % 7 + 7) % 7
    }
}

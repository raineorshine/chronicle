import Foundation

/// Pure date logic for the weekly chart's X axis: week-range labels for the
/// short windows and month divisions for the long ones. Kept free of SwiftUI so
/// it is unit-testable.
public enum ChartAxis {
    /// Label for a week tick covering the week's whole span, e.g. "Jul 6–12".
    /// When the week straddles a month boundary the month repeats on the end
    /// date: "Jun 29–Jul 5".
    public static func weekRangeLabel(weekStart: Date,
                                      calendar: Calendar,
                                      locale: Locale = .current) -> String {
        let end = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        let start = monthDayLabel(for: weekStart, calendar: calendar, locale: locale)
        let sameMonth = calendar.isDate(weekStart, equalTo: end, toGranularity: .month)
        let endLabel = sameMonth
            ? formatter(template: "d", calendar: calendar, locale: locale).string(from: end)
            : monthDayLabel(for: end, calendar: calendar, locale: locale)
        return "\(start)–\(endLabel)"
    }

    /// Month-day label for a single date, e.g. "Jul 6".
    public static func monthDayLabel(for date: Date,
                                     calendar: Calendar,
                                     locale: Locale = .current) -> String {
        formatter(template: "MMMd", calendar: calendar, locale: locale).string(from: date)
    }

    /// Month-name label, e.g. "Jul".
    public static func monthLabel(for date: Date,
                                  calendar: Calendar,
                                  locale: Locale = .current) -> String {
        formatter(template: "MMM", calendar: calendar, locale: locale).string(from: date)
    }

    /// First-of-month dates strictly inside `domain` — where the chart draws its
    /// month divider rules. The domain endpoints are excluded because the plot
    /// edges already bound the first and last month.
    public static func monthBoundaries(in domain: ClosedRange<Date>,
                                       calendar: Calendar) -> [Date] {
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month],
                                                                     from: domain.lowerBound))
        else { return [] }
        var cursor = first
        var result: [Date] = []
        while cursor < domain.upperBound {
            if cursor > domain.lowerBound { result.append(cursor) }
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    /// Start of each month's visible span within `domain`, where its name is
    /// drawn — the divider for a full month, the domain edge for the partial
    /// month the window opens in. Spans shorter than `minimumDays` are skipped:
    /// the label is left-aligned to the start, so a sliver of a month would push
    /// its name across the next divider.
    public static func monthLabelDates(in domain: ClosedRange<Date>,
                                       calendar: Calendar,
                                       minimumDays: Int = 7) -> [Date] {
        let starts = [domain.lowerBound] + monthBoundaries(in: domain, calendar: calendar)
        let ends = starts.dropFirst() + [domain.upperBound]
        let minimumSpan = Double(minimumDays) * 86_400
        return zip(starts, ends).compactMap { start, end in
            end.timeIntervalSince(start) >= minimumSpan ? start : nil
        }
    }

    private static func formatter(template: String,
                                  calendar: Calendar,
                                  locale: Locale) -> DateFormatter {
        let out = DateFormatter()
        out.calendar = calendar
        out.timeZone = calendar.timeZone
        out.locale = locale
        out.setLocalizedDateFormatFromTemplate(template)
        return out
    }
}

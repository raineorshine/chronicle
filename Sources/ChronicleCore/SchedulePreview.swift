import Foundation

/// How often a calendar series repeats. Mirrors `EKRecurrenceFrequency`, kept
/// separate so the preview rules stay EventKit-free and testable.
public enum ScheduleFrequency: Equatable, Sendable {
    case daily
    case weekly
    case monthly
    case yearly
}

/// One upcoming occurrence of a task. `frequency` is nil for a one-off event,
/// which the preview ignores.
public struct ScheduleOccurrence: Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let frequency: ScheduleFrequency?

    public init(start: Date, end: Date, frequency: ScheduleFrequency?) {
        self.start = start
        self.end = end
        self.frequency = frequency
    }
}

/// One occurrence plotted in the week preview.
public struct ScheduleMark: Equatable {
    /// Position of the occurrence's start down the 8am–10pm band, `0` = 8am …
    /// `1` = 10pm.
    public let fraction: Double
    /// How much of the band the occurrence covers, so a mark can be drawn as long
    /// as the event runs. Counts only the part inside the band: an event starting
    /// before 8am contributes from 8am on.
    public let durationFraction: Double
    /// The occurrence's start as minutes from midnight. Carried alongside
    /// `fraction`, which clamps, so labels can state the real time.
    public let minutes: Int

    public init(fraction: Double, durationFraction: Double, minutes: Int) {
        self.fraction = fraction
        self.durationFraction = durationFraction
        self.minutes = minutes
    }
}

/// The compact schedule shown beside a task's name: either the current week or,
/// for a task that only recurs monthly, the current month.
public enum SchedulePreview: Equatable {
    /// Seven columns, Monday…Sunday, each holding that day's marks.
    case week(days: [[ScheduleMark]])
    case month(MonthPreview)
}

/// A month laid out as a Monday-first grid: `leadingBlanks` empty cells, then
/// `dayCount` day cells, of which `markedDays` carry an occurrence.
public struct MonthPreview: Equatable {
    public let leadingBlanks: Int
    public let dayCount: Int
    /// 1-based days of the month that have at least one occurrence.
    public let markedDays: Set<Int>
    /// 1-based day of the month for today, when today falls in this month.
    public let today: Int?

    public init(leadingBlanks: Int, dayCount: Int, markedDays: Set<Int>, today: Int?) {
        self.leadingBlanks = leadingBlanks
        self.dayCount = dayCount
        self.markedDays = markedDays
        self.today = today
    }
}

/// Turns a task's upcoming occurrences into the compact preview drawn next to its
/// name. Pure — no EventKit, no I/O — so every rule below is directly testable.
public enum SchedulePreviewBuilder {

    /// The band the week preview plots, chosen to cover a normal waking day in
    /// very little vertical space. Occurrences outside it clamp to an edge rather
    /// than disappearing.
    public static let dayStartHour = 8.0
    public static let dayEndHour = 22.0

    /// Builds the preview for `occurrences`, or nil when nothing recurring falls
    /// in range.
    ///
    /// Only recurring events are plotted: the preview exists to show the *pattern*
    /// of a routine, and a one-off event would read as part of that pattern when
    /// it will never happen again.
    ///
    /// The month grid is reserved for tasks that *only* recur monthly (or yearly):
    /// a week preview would show such a task as empty most weeks. Everything else
    /// — weekly, daily, or a mix — reads better as the current Monday–Sunday week.
    public static func build(occurrences: [ScheduleOccurrence],
                             now: Date,
                             calendar: Calendar) -> SchedulePreview? {
        let recurring = occurrences.filter { $0.frequency != nil }
        guard !recurring.isEmpty else { return nil }
        return isMonthly(recurring)
            ? month(recurring, now: now, calendar: calendar)
            : week(recurring, now: now, calendar: calendar)
    }

    /// True when every series recurs no more often than monthly. Expects the
    /// non-recurring occurrences to have been dropped already.
    private static func isMonthly(_ occurrences: [ScheduleOccurrence]) -> Bool {
        occurrences.allSatisfy { $0.frequency == .monthly || $0.frequency == .yearly }
    }

    private static func week(_ occurrences: [ScheduleOccurrence],
                             now: Date,
                             calendar: Calendar) -> SchedulePreview? {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return nil }
        var days: [[ScheduleMark]] = Array(repeating: [], count: 7)
        for occurrence in occurrences where week.contains(occurrence.start) {
            let index = mondayIndex(of: occurrence.start, calendar: calendar)
            guard days.indices.contains(index) else { continue }
            days[index].append(mark(for: occurrence, calendar: calendar))
        }
        guard days.contains(where: { !$0.isEmpty }) else { return nil }
        return .week(days: days.map { $0.sorted { $0.minutes < $1.minutes } })
    }

    private static func month(_ occurrences: [ScheduleOccurrence],
                              now: Date,
                              calendar: Calendar) -> SchedulePreview? {
        guard let month = calendar.dateInterval(of: .month, for: now),
              let dayCount = calendar.range(of: .day, in: .month, for: now)?.count
        else { return nil }

        let marked = Set(occurrences
            .filter { month.contains($0.start) }
            .map { calendar.component(.day, from: $0.start) })
        guard !marked.isEmpty else { return nil }

        return .month(MonthPreview(leadingBlanks: mondayIndex(of: month.start, calendar: calendar),
                                   dayCount: dayCount,
                                   markedDays: marked,
                                   today: calendar.component(.day, from: now)))
    }

    /// Column index for a date, 0 = Monday … 6 = Sunday. Independent of the
    /// calendar's `firstWeekday`, so the preview's columns always read M→Su.
    private static func mondayIndex(of date: Date, calendar: Calendar) -> Int {
        // Foundation numbers weekdays 1 = Sunday … 7 = Saturday.
        (calendar.component(.weekday, from: date) + 5) % 7
    }

    /// Places an occurrence in the 8am–10pm band, as a start position and the
    /// share of the band it runs for.
    ///
    /// Times outside the band clamp to an edge, so an early-morning or late-night
    /// task still shows up pinned to the top or bottom rather than vanishing; the
    /// mark's `minutes` keeps the unclamped start for labels. Because both ends
    /// clamp, an event that begins before 8am is measured from 8am — the preview
    /// shows the part of it that the band can hold.
    private static func mark(for occurrence: ScheduleOccurrence,
                             calendar: Calendar) -> ScheduleMark {
        let minutes = minutesIntoDay(occurrence.start, calendar: calendar)
        let start = bandFraction(minutes)
        // An event running past midnight has no meaningful time-of-day end, so it
        // simply runs to the bottom of the band.
        let end = calendar.isDate(occurrence.end, inSameDayAs: occurrence.start)
            ? bandFraction(minutesIntoDay(occurrence.end, calendar: calendar))
            : 1
        return ScheduleMark(fraction: start,
                            durationFraction: max(0, end - start),
                            minutes: minutes)
    }

    private static func minutesIntoDay(_ date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// Where a time of day sits in the band, clamped to `0...1`.
    private static func bandFraction(_ minutesIntoDay: Int) -> Double {
        let fraction = (Double(minutesIntoDay) / 60 - dayStartHour) / (dayEndHour - dayStartHour)
        return min(max(fraction, 0), 1)
    }
}

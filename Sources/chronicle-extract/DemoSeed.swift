import Foundation
import ChronicleCore

/// Synthetic data used by `chronicle-extract --demo` to populate the dashboard
/// without requiring Calendar access. Events land inside the rolling window, so
/// a later real extraction run overwrites them.
enum SyntheticData {

    static func events(calendar: Calendar) -> [EventInput] {
        var events: [EventInput] = []

        func date(_ dayOffset: Int, _ hour: Int, _ minute: Int) -> Date {
            let today = calendar.startOfDay(for: Date())
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: today)!
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        }

        func add(_ title: String, calendarName: String,
                 day: Int, from: (Int, Int), to: (Int, Int)) {
            guard let parsed = TitleParser.parse(title) else { return }
            events.append(EventInput(
                calendar: TitleParser.normalize(calendarName),
                title: parsed,
                start: date(day, from.0, from.1),
                end: date(day, to.0, to.1),
                isAllDay: false))
        }

        func addSpan(_ title: String, calendarName: String,
                     startDay: Int, from: (Int, Int),
                     endDay: Int, to: (Int, Int)) {
            guard let parsed = TitleParser.parse(title) else { return }
            events.append(EventInput(
                calendar: TitleParser.normalize(calendarName),
                title: parsed,
                start: date(startDay, from.0, from.1),
                end: date(endDay, to.0, to.1),
                isAllDay: false))
        }

        // Two weeks of plausible activity.
        for day in 0..<28 {
            let weekday = calendar.component(.weekday,
                                             from: date(day, 12, 0)) // 1=Sun … 7=Sat
            let isWeekend = (weekday == 1 || weekday == 7)

            if !isWeekend {
                add("⚙️ Code Reviews (%2)", calendarName: "Personal",
                    day: day, from: (9, 0), to: (10, 30))
                add("em - accounting", calendarName: "Work",
                    day: day, from: (11, 0), to: (12, 15))
                if day % 2 == 0 {
                    add("em - design", calendarName: "Work",
                        day: day, from: (13, 0), to: (14, 30))
                }
                if day % 3 == 0 {
                    add("em", calendarName: "Work",
                        day: day, from: (15, 0), to: (16, 0))
                }
                add("Reading", calendarName: "Personal",
                    day: day, from: (20, 0), to: (21, 0))
            } else {
                add("Gym", calendarName: "Personal",
                    day: day, from: (10, 0), to: (11, 30))
                add("Reading", calendarName: "Personal",
                    day: day, from: (16, 0), to: (18, 0))
            }
        }

        // A late deploy that crosses midnight (splits across two days).
        // startDay 5 = 5 days ago at 22:30 → endDay 4 = next day at 00:30.
        addSpan("em - deploy", calendarName: "Work",
                startDay: 5, from: (22, 30), endDay: 4, to: (0, 30))

        return events
    }
}

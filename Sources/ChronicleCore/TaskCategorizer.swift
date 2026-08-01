import Foundation

/// Builds the retitled event names for a *categorize*: filing an activity under
/// another task without losing what the event actually was.
///
/// Only the part in front of the separator changes. `Health - Dr. Brown` filed
/// under `Wellbeing` becomes `Wellbeing - Dr. Brown`, and an uncategorized
/// `Faiz` becomes `em - Faiz` — with nothing to keep in the subtask slot, the
/// old task slides down into it rather than being dropped.
///
/// The kept part is carried over *raw*, not normalized, so everything the parser
/// strips for display — emoji, `(...)` metadata, `%n` tokens — survives.
public enum TaskCategorizer {

    /// The new title for `rawTitle` filed under `categoryLabel`, or nil when the
    /// title has nothing worth keeping or already reads that way.
    public static func categorizedTitle(rawTitle: String,
                                        categoryLabel: String,
                                        separators: [String] = [" - ", " | ", " / "]) -> String? {
        let category = categoryLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !category.isEmpty else { return nil }

        let (taskPart, subtaskPart, separator) = split(rawTitle, separators: separators)
        // The event's leaf: its subtask, or its task when it has no subtask.
        let kept = (subtaskPart ?? taskPart).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kept.isEmpty else { return nil }

        // Rejoin with the separator the title already used, so a `Task | Sub`
        // convention isn't quietly rewritten to ` - `.
        let title = category + (separator ?? separators.first ?? " - ") + kept
        return title == rawTitle ? nil : title
    }

    /// Splits at the earliest separator, reporting which one matched. Mirrors
    /// `TitleParser.split`, which discards the separator it used.
    private static func split(_ raw: String,
                              separators: [String]) -> (String, String?, String?) {
        var best: (range: Range<String.Index>, separator: String)?
        for separator in separators where !separator.isEmpty {
            guard let range = raw.range(of: separator) else { continue }
            if best == nil || range.lowerBound < best!.range.lowerBound {
                best = (range, separator)
            }
        }
        guard let best else { return (raw, nil, nil) }
        return (String(raw[raw.startIndex..<best.range.lowerBound]),
                String(raw[best.range.upperBound...]),
                best.separator)
    }
}

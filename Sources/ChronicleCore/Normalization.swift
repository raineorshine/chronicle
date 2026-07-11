import Foundation

/// Title normalization and Task/Subtask parsing.
///
/// Pipeline for each component (see spec "Normalization Rules"):
/// 1. Unicode NFC normalize.
/// 2. Remove emoji.
/// 3. Remove parenthesized metadata, e.g. `(%2)`.
/// 4. Remove remaining punctuation/symbols.
/// 5. Collapse whitespace.
/// 6. Trim.
/// 7. Lowercase for the comparison key; preserve original case as the label.
///
/// Note: parenthesized metadata is removed *before* generic punctuation.
/// Stripping punctuation first would delete the parentheses and make the
/// `(...)` metadata undetectable.
public enum TitleParser {

    /// Parses a raw event title into a Task and optional Subtask.
    /// Returns `nil` when the title has no usable Task after normalization.
    public static func parse(_ raw: String, separator: String = " - ") -> ParsedTitle? {
        let (taskPart, subtaskPart) = split(raw, separator: separator)

        let task = normalize(taskPart)
        guard !task.isEmpty else { return nil }

        if let subtaskPart {
            let subtask = normalize(subtaskPart)
            return ParsedTitle(task: task, subtask: subtask.isEmpty ? nil : subtask)
        }
        return ParsedTitle(task: task, subtask: nil)
    }

    /// Splits a raw title on the first occurrence of the subtask separator.
    /// Ordinary hyphenated words (no surrounding spaces) are not split.
    static func split(_ raw: String, separator: String) -> (String, String?) {
        guard !separator.isEmpty, let range = raw.range(of: separator) else {
            return (raw, nil)
        }
        let task = String(raw[raw.startIndex..<range.lowerBound])
        let subtask = String(raw[range.upperBound...])
        return (task, subtask)
    }

    /// Runs the normalization pipeline on a single component and produces a
    /// `NormalizedName` (canonical label + lowercased key).
    public static func normalize(_ component: String) -> NormalizedName {
        var text = component.precomposedStringWithCanonicalMapping   // 1. NFC
        text = removeEmoji(text)                                      // 2. emoji
        text = removeParenthesizedMetadata(text)                     // 3. (...)
        text = removePunctuation(text)                               // 4. punctuation
        text = collapseWhitespace(text)                             // 5. + 6.
        let label = text
        return NormalizedName(label: label, key: label.lowercased())
    }

    // MARK: - Steps

    private static func removeEmoji(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            if isEmojiScalar(scalar) { continue }
            scalars.append(scalar)
        }
        return String(scalars)
    }

    private static func isEmojiScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if scalar.properties.isEmojiPresentation { return true }
        switch v {
        case 0x200D,                    // zero-width joiner
             0xFE00...0xFE0F,           // variation selectors
             0x1F3FB...0x1F3FF,         // skin-tone modifiers
             0x2600...0x27BF,           // misc symbols + dingbats (incl. ⚙ U+2699)
             0x2B00...0x2BFF,           // misc symbols & arrows
             0x1F000...0x1FAFF,         // emoji / pictograph blocks
             0x1F1E6...0x1F1FF:         // regional indicators
            return true
        default:
            return false
        }
    }

    private static func removeParenthesizedMetadata(_ s: String) -> String {
        // Remove any `( ... )` group, including the parentheses.
        var result = ""
        var depth = 0
        for ch in s {
            if ch == "(" {
                depth += 1
            } else if ch == ")" {
                if depth > 0 { depth -= 1 }
            } else if depth == 0 {
                result.append(ch)
            }
        }
        return result
    }

    private static func removePunctuation(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        let alphanumerics = CharacterSet.alphanumerics
        let whitespace = CharacterSet.whitespaces
        for scalar in s.unicodeScalars {
            if alphanumerics.contains(scalar) || whitespace.contains(scalar) {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    private static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

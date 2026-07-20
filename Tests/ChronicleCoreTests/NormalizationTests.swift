import XCTest
@testable import ChronicleCore

final class NormalizationTests: XCTestCase {

    func testEmojiKeptInLabelStrippedFromKey() {
        // "⚙️ Code Reviews (%2)" -> label keeps the emoji; key drops it.
        let parsed = TitleParser.parse("⚙️ Code Reviews (%2)")
        XCTAssertEqual(parsed?.task.label, "⚙️ Code Reviews")
        XCTAssertEqual(parsed?.task.key, "code reviews")
        XCTAssertNil(parsed?.subtask)
    }

    func testEmojiVariantsShareKeyButKeepDistinctLabels() {
        // "🚶Walk" and "👟Walk" are one activity (same key) with distinct labels.
        let walking = TitleParser.parse("🚶Walk")
        let sneaker = TitleParser.parse("👟Walk")
        XCTAssertEqual(walking?.task.key, "walk")
        XCTAssertEqual(sneaker?.task.key, "walk")
        XCTAssertEqual(walking?.task.key, sneaker?.task.key)
        XCTAssertEqual(walking?.task.label, "🚶Walk")
        XCTAssertEqual(sneaker?.task.label, "👟Walk")
        XCTAssertNotEqual(walking?.task.label, sneaker?.task.label)
    }

    func testTaskSubtaskSplit() {
        // "em - accounting" -> task: em, subtask: accounting
        let parsed = TitleParser.parse("em - accounting")
        XCTAssertEqual(parsed?.task.label, "em")
        XCTAssertEqual(parsed?.subtask?.label, "accounting")
        XCTAssertEqual(parsed?.subtask?.key, "accounting")
    }

    func testPipeSeparatorSplit() {
        // "em | Code Reviews" -> task: em, subtask: Code Reviews
        let parsed = TitleParser.parse("em | Code Reviews")
        XCTAssertEqual(parsed?.task.label, "em")
        XCTAssertEqual(parsed?.subtask?.label, "Code Reviews")
        XCTAssertEqual(parsed?.subtask?.key, "code reviews")
    }

    func testLeftmostSeparatorWinsAcrossDelimiters() {
        // "a - b | c" -> split at the leftmost separator; the rest stays in the subtask.
        let parsed = TitleParser.parse("a - b | c")
        XCTAssertEqual(parsed?.task.label, "a")
        // The pipe is stripped as punctuation during normalization of the subtask.
        XCTAssertEqual(parsed?.subtask?.label, "b c")
    }

    func testPipeWithoutSpacesIsNotSplit() {
        // No spaces around the pipe -> not a separator.
        let parsed = TitleParser.parse("a|b")
        XCTAssertNil(parsed?.subtask)
        XCTAssertEqual(parsed?.task.label, "ab") // pipe stripped as punctuation
    }

    func testPlainTaskHasNoSubtask() {
        let parsed = TitleParser.parse("em")
        XCTAssertEqual(parsed?.task.key, "em")
        XCTAssertNil(parsed?.subtask)
    }

    func testHyphenatedWordsAreNotSplit() {
        // No spaces around the hyphen -> not a separator.
        let parsed = TitleParser.parse("Well-being")
        XCTAssertNil(parsed?.subtask)
        XCTAssertEqual(parsed?.task.label, "Wellbeing") // hyphen stripped as punctuation
    }

    func testCaseInsensitiveKeyPreservesLabel() {
        let parsed = TitleParser.parse("Code Reviews")
        XCTAssertEqual(parsed?.task.label, "Code Reviews")
        XCTAssertEqual(parsed?.task.key, "code reviews")
    }

    func testWhitespaceCollapseAndTrim() {
        let parsed = TitleParser.parse("   em    -    accounting   ")
        XCTAssertEqual(parsed?.task.label, "em")
        XCTAssertEqual(parsed?.subtask?.label, "accounting")
    }

    func testEmptyTitleReturnsNil() {
        XCTAssertNil(TitleParser.parse("   "))
        XCTAssertNil(TitleParser.parse("🎉"))
        XCTAssertNil(TitleParser.parse("(only metadata)"))
    }

    func testSubtaskEmptyAfterNormalizationIsNil() {
        let parsed = TitleParser.parse("em - (%2)")
        XCTAssertEqual(parsed?.task.key, "em")
        XCTAssertNil(parsed?.subtask)
    }

    func testUnicodeNormalization() {
        // Composed vs decomposed "é" should compare equal.
        let composed = TitleParser.parse("caf\u{00E9}")     // é
        let decomposed = TitleParser.parse("cafe\u{0301}")  // e + combining acute
        XCTAssertEqual(composed?.task.key, decomposed?.task.key)
    }
}

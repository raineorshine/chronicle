import XCTest
@testable import ChronicleCore

final class NormalizationTests: XCTestCase {

    func testEmojiAndParentheticalRemoval() {
        // "⚙️ Code Reviews (%2)" -> "Code Reviews"
        let parsed = TitleParser.parse("⚙️ Code Reviews (%2)")
        XCTAssertEqual(parsed?.task.label, "Code Reviews")
        XCTAssertEqual(parsed?.task.key, "code reviews")
        XCTAssertNil(parsed?.subtask)
    }

    func testTaskSubtaskSplit() {
        // "em - accounting" -> task: em, subtask: accounting
        let parsed = TitleParser.parse("em - accounting")
        XCTAssertEqual(parsed?.task.label, "em")
        XCTAssertEqual(parsed?.subtask?.label, "accounting")
        XCTAssertEqual(parsed?.subtask?.key, "accounting")
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

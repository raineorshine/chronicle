import XCTest
@testable import ChronicleCore

final class TaskCategorizerTests: XCTestCase {

    private func categorized(_ raw: String,
                             _ category: String,
                             separators: [String] = [" - ", " | ", " / "]) -> String? {
        TaskCategorizer.categorizedTitle(rawTitle: raw,
                                         categoryLabel: category,
                                         separators: separators)
    }

    // MARK: - The two shapes a title can have

    func testUncategorizedTitleSlidesDownIntoTheSubtask() {
        XCTAssertEqual(categorized("Faiz", "em"), "em - Faiz")
    }

    func testCategorizedTitleKeepsItsSubtask() {
        XCTAssertEqual(categorized("Health - Dr. Brown", "Wellbeing"), "Wellbeing - Dr. Brown")
    }

    func testOnlyTheLeftmostSeparatorSplits() {
        // The whole remainder is the subtask, so a second separator rides along.
        XCTAssertEqual(categorized("Health - Dr. Brown - Follow-up", "Wellbeing"),
                       "Wellbeing - Dr. Brown - Follow-up")
    }

    // MARK: - What survives the rewrite

    func testKeepsMetadataTheParserWouldStripForDisplay() {
        // `(%2)` and emoji are display-normalized away, but this writes a real
        // calendar title, so the raw subtask text is carried over untouched.
        XCTAssertEqual(categorized("Health - 🩺 Dr. Brown (%2)", "Wellbeing"),
                       "Wellbeing - 🩺 Dr. Brown (%2)")
    }

    func testKeepsTheSeparatorTheTitleAlreadyUsed() {
        XCTAssertEqual(categorized("Health | Dr. Brown", "Wellbeing"), "Wellbeing | Dr. Brown")
        XCTAssertEqual(categorized("Health / Dr. Brown", "Wellbeing"), "Wellbeing / Dr. Brown")
    }

    func testUsesTheFirstConfiguredSeparatorWhenThereIsNothingToSplit() {
        XCTAssertEqual(categorized("Faiz", "em", separators: [" | ", " - "]), "em | Faiz")
    }

    func testEarliestSeparatorWinsRegardlessOfConfiguredOrder() {
        XCTAssertEqual(categorized("Health | Dr. Brown - Follow-up", "Wellbeing"),
                       "Wellbeing | Dr. Brown - Follow-up")
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(categorized("  Faiz  ", "  em  "), "em - Faiz")
    }

    // MARK: - Nothing to do

    func testNilWhenTheTitleAlreadyReadsThatWay() {
        XCTAssertNil(categorized("Wellbeing - Dr. Brown", "Wellbeing"))
    }

    func testNilWhenThereIsNothingToKeep() {
        XCTAssertNil(categorized("   ", "em"))
        XCTAssertNil(categorized("Health - ", "Wellbeing"))
    }

    func testNilWhenTheCategoryIsEmpty() {
        XCTAssertNil(categorized("Faiz", "   "))
    }
}

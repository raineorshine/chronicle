import XCTest
@testable import ChronicleCore

final class ConfigTests: XCTestCase {

    func testRoundTripPreservesWholeCalendarSegments() throws {
        let config = ChronicleConfig(calendarAllowlist: ["Work"],
                                     wholeCalendarSegments: ["Raine Revere"])
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ChronicleConfig.self, from: data)
        XCTAssertEqual(decoded.wholeCalendarSegments, ["Raine Revere"])
        XCTAssertEqual(decoded, config)
    }

    func testTolerantDecodeDefaultsMissingWholeCalendarSegments() throws {
        // A config written by an older version lacks the new key entirely.
        let json = #"{"calendarAllowlist":["Work"],"subtaskSeparator":" - "}"#
        let decoded = try JSONDecoder().decode(ChronicleConfig.self,
                                               from: Data(json.utf8))
        XCTAssertEqual(decoded.wholeCalendarSegments, [])
        XCTAssertEqual(decoded.calendarAllowlist, ["Work"])
    }

    func testRoundTripPreservesAliasChains() throws {
        let chains = [["VP of Engineering", "em - Code Reviews", "em - Engineering Lead"]]
        let config = ChronicleConfig(aliasChains: chains)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ChronicleConfig.self, from: data)
        XCTAssertEqual(decoded.aliasChains, chains)
        XCTAssertEqual(decoded, config)
    }

    func testTolerantDecodeDefaultsMissingAliasChains() throws {
        let json = #"{"calendarAllowlist":["Work"],"subtaskSeparator":" - "}"#
        let decoded = try JSONDecoder().decode(ChronicleConfig.self,
                                               from: Data(json.utf8))
        XCTAssertEqual(decoded.aliasChains, [])
    }

    func testLegacySingleSeparatorMigratesToList() throws {
        // Older configs stored a single `subtaskSeparator` string.
        let json = #"{"calendarAllowlist":["Work"],"subtaskSeparator":" / "}"#
        let decoded = try JSONDecoder().decode(ChronicleConfig.self,
                                               from: Data(json.utf8))
        XCTAssertEqual(decoded.subtaskSeparators, [" / "])
    }

    func testMissingSeparatorDefaultsToHyphenPipeAndSlash() throws {
        let json = #"{"calendarAllowlist":["Work"]}"#
        let decoded = try JSONDecoder().decode(ChronicleConfig.self,
                                               from: Data(json.utf8))
        XCTAssertEqual(decoded.subtaskSeparators, [" - ", " | ", " / "])
    }

    func testRoundTripPreservesSeparatorList() throws {
        let config = ChronicleConfig(subtaskSeparators: [" - ", " | "])
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ChronicleConfig.self, from: data)
        XCTAssertEqual(decoded.subtaskSeparators, [" - ", " | "])
        XCTAssertEqual(decoded, config)
    }

    // MARK: - Calendar priority order

    func testAllowlistOrderIsPreservedAsPriority() throws {
        let config = ChronicleConfig(calendarAllowlist: ["Sleep", "Work", "Personal"])
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ChronicleConfig.self, from: data)
        XCTAssertEqual(decoded.calendarAllowlist, ["Sleep", "Work", "Personal"])
    }

    func testLegacySubtractiveCalendarsMigrateToTopOfPriorityOrder() throws {
        // The old flag meant "outranks everything", which is now the top slot.
        let json = #"{"calendarAllowlist":["Work","Instagram","Personal"],"subtractiveCalendars":["Instagram"]}"#
        let decoded = try JSONDecoder().decode(ChronicleConfig.self,
                                               from: Data(json.utf8))
        XCTAssertEqual(decoded.calendarAllowlist, ["Instagram", "Work", "Personal"])
    }

    func testLegacySubtractiveCalendarOutsideAllowlistIsIncluded() throws {
        // A subtractive calendar used to be extracted even when unlisted.
        let json = #"{"calendarAllowlist":["Work"],"subtractiveCalendars":["Sleep"]}"#
        let decoded = try JSONDecoder().decode(ChronicleConfig.self,
                                               from: Data(json.utf8))
        XCTAssertEqual(decoded.calendarAllowlist, ["Sleep", "Work"])
    }

    func testLegacySubtractiveMatchIsCaseInsensitive() throws {
        // The allowlist keeps its own casing and is not duplicated.
        let json = #"{"calendarAllowlist":["Work","instagram"],"subtractiveCalendars":["Instagram"]}"#
        let decoded = try JSONDecoder().decode(ChronicleConfig.self,
                                               from: Data(json.utf8))
        XCTAssertEqual(decoded.calendarAllowlist, ["Instagram", "Work"])
    }

    func testEncodedConfigDropsLegacySubtractiveKey() throws {
        let json = #"{"calendarAllowlist":["Work"],"subtractiveCalendars":["Sleep"]}"#
        let decoded = try JSONDecoder().decode(ChronicleConfig.self, from: Data(json.utf8))
        let reencoded = String(data: try JSONEncoder().encode(decoded), encoding: .utf8)!
        XCTAssertFalse(reencoded.contains("subtractiveCalendars"))
    }

    func testWeeklyMetricsCutoffDefaultsToFriday() {
        XCTAssertEqual(ChronicleConfig.default.weeklyMetricsCutoff, 6)
    }

    func testRoundTripPreservesWeeklyMetricsCutoff() throws {
        let config = ChronicleConfig(weeklyMetricsCutoff: 3)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ChronicleConfig.self, from: data)
        XCTAssertEqual(decoded.weeklyMetricsCutoff, 3)
        XCTAssertEqual(decoded, config)
    }

    func testTolerantDecodeDefaultsMissingWeeklyMetricsCutoff() throws {
        // A config written before the cutoff key existed still loads.
        let json = #"{"calendarAllowlist":["Work"]}"#
        let decoded = try JSONDecoder().decode(ChronicleConfig.self,
                                               from: Data(json.utf8))
        XCTAssertEqual(decoded.weeklyMetricsCutoff, 6)
    }
}

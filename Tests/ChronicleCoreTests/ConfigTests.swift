import XCTest
@testable import ChronicleCore

final class ConfigTests: XCTestCase {

    func testRoundTripPreservesWholeCalendarSegments() throws {
        let config = ChronicleConfig(calendarAllowlist: ["Work"],
                                     subtractiveCalendars: ["Sleep"],
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
}

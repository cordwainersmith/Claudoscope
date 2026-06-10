import XCTest
@testable import Claudoscope

/// Unit tests for the pure `DataCoverage.compute` and its derived flags. The
/// coverage badge tells the user the cost estimate only covers transcripts on
/// this Mac, so the missing-count math and the warning thresholds must be exact.
final class DataCoverageTests: XCTestCase {

    private func entry(sessionId: String?) -> HistoryEntry {
        HistoryEntry(
            id: UUID().uuidString,
            type: "user",
            sessionId: sessionId,
            project: nil,
            projectId: nil,
            timestamp: Date(timeIntervalSince1970: 0),
            display: ""
        )
    }

    // MARK: - missing count

    func testMissingCountIgnoresDuplicateAndNilSessionIds() {
        let history = [
            entry(sessionId: "a"),
            entry(sessionId: "a"),   // duplicate — counted once
            entry(sessionId: "b"),
            entry(sessionId: nil),   // dropped by compactMap
            entry(sessionId: "c"),
        ]
        let coverage = DataCoverage.compute(
            historyEntries: history,
            knownSessionIds: ["a", "c"],
            cleanupPeriodDays: 365,
            oldestFirstTimestamp: nil
        )
        XCTAssertEqual(coverage.missingTranscriptCount, 1, "only 'b' is in history but missing locally")
    }

    func testMissingCountZeroWhenAllKnown() {
        let history = [entry(sessionId: "a"), entry(sessionId: "b")]
        let coverage = DataCoverage.compute(
            historyEntries: history,
            knownSessionIds: ["a", "b"],
            cleanupPeriodDays: 365,
            oldestFirstTimestamp: nil
        )
        XCTAssertEqual(coverage.missingTranscriptCount, 0)
    }

    // MARK: - oldest transcript date

    func testOldestDateParsedFromTimestamp() {
        let ts = "2026-04-26T10:00:00.000Z"
        let coverage = DataCoverage.compute(
            historyEntries: [],
            knownSessionIds: [],
            cleanupPeriodDays: 365,
            oldestFirstTimestamp: ts
        )
        XCTAssertEqual(coverage.oldestTranscriptDate, ISO8601.parse(ts))
    }

    func testOldestDateNilWhenTimestampMissingOrUnparseable() {
        let none = DataCoverage.compute(historyEntries: [], knownSessionIds: [],
                                        cleanupPeriodDays: 365, oldestFirstTimestamp: nil)
        XCTAssertNil(none.oldestTranscriptDate)

        let garbage = DataCoverage.compute(historyEntries: [], knownSessionIds: [],
                                           cleanupPeriodDays: 365, oldestFirstTimestamp: "not-a-date")
        XCTAssertNil(garbage.oldestTranscriptDate)
    }

    // MARK: - effective cleanup days

    func testEffectiveCleanupDaysDefaultsTo30WhenUnset() {
        let coverage = DataCoverage.compute(historyEntries: [], knownSessionIds: [],
                                            cleanupPeriodDays: nil, oldestFirstTimestamp: nil)
        XCTAssertEqual(coverage.effectiveCleanupDays, 30)
    }

    func testEffectiveCleanupDaysUsesConfiguredValue() {
        let coverage = DataCoverage.compute(historyEntries: [], knownSessionIds: [],
                                            cleanupPeriodDays: 90, oldestFirstTimestamp: nil)
        XCTAssertEqual(coverage.effectiveCleanupDays, 90)
    }

    // MARK: - isWarning truth table

    func testIsWarningWhenTranscriptsMissing() {
        // Missing > 0 warns even with a generous retention window.
        let coverage = DataCoverage.compute(historyEntries: [entry(sessionId: "a")],
                                            knownSessionIds: [], cleanupPeriodDays: 365,
                                            oldestFirstTimestamp: nil)
        XCTAssertTrue(coverage.isWarning)
    }

    func testIsWarningWhenRetentionShortEvenIfNothingMissing() {
        for days in [nil, 1, 30] as [Int?] {
            let coverage = DataCoverage.compute(historyEntries: [], knownSessionIds: [],
                                                cleanupPeriodDays: days, oldestFirstTimestamp: nil)
            XCTAssertTrue(coverage.isWarning, "retention \(String(describing: days)) (<= 30) should warn")
        }
    }

    func testNoWarningWhenCompleteAndLongRetention() {
        for days in [31, 365] {
            let coverage = DataCoverage.compute(historyEntries: [], knownSessionIds: [],
                                                cleanupPeriodDays: days, oldestFirstTimestamp: nil)
            XCTAssertFalse(coverage.isWarning, "retention \(days) (> 30) with no gaps should not warn")
        }
    }
}

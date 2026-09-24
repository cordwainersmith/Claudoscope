import XCTest
@testable import Claudoscope

final class FleetWaitStatsTests: XCTestCase {
    private let day = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 12))!
    private var dayKey: String { ISO8601.localDayKey(for: day) }

    private func wait(start offset: TimeInterval, duration: TimeInterval?, turnAgo: TimeInterval = 10,
                      ttl: Int? = 300, tokens: Int? = 1_000_000,
                      model: String? = "claude-sonnet-4-5") -> FleetWaitRecord {
        let start = day.addingTimeInterval(offset).timeIntervalSince1970
        return FleetWaitRecord(
            id: nil, sessionId: "s", projectId: "p", kind: "permission",
            startedAt: start, endedAt: duration.map { start + $0 },
            contextTokens: tokens, cacheTtlSeconds: ttl, turnTimestamp: start - turnAgo, model: model)
    }

    func testMeanAndMax() throws {
        let stats = try XCTUnwrap(FleetWaitStats.summarize(
            [wait(start: 0, duration: 30), wait(start: 60, duration: 90)],
            dayKey: dayKey, pricingTable: PricingTables.anthropic))
        XCTAssertEqual(stats.count, 2)
        XCTAssertEqual(stats.meanSeconds, 60, accuracy: 0.001)
        XCTAssertEqual(stats.maxSeconds, 90, accuracy: 0.001)
        XCTAssertEqual(stats.coldRestartCount, 0)
    }

    func testDayFilter() throws {
        let stats = try XCTUnwrap(FleetWaitStats.summarize(
            [wait(start: 0, duration: 30), wait(start: -2 * 86400, duration: 600)],
            dayKey: dayKey, pricingTable: PricingTables.anthropic))
        XCTAssertEqual(stats.count, 1)
    }

    func testColdBoundary() {
        // Turn 10s before the wait, 300s TTL: cache expires 290s into the wait.
        XCTAssertFalse(FleetWaitStats.isColdRestart(wait(start: 0, duration: 290)))
        XCTAssertTrue(FleetWaitStats.isColdRestart(wait(start: 0, duration: 291)))
        XCTAssertFalse(FleetWaitStats.isColdRestart(wait(start: 0, duration: 900, ttl: nil)))
    }

    func testColdCostUsesTierRate() {
        let fiveMinute = wait(start: 0, duration: 900, ttl: 300)
        let oneHour = wait(start: 0, duration: 4000, ttl: 3600)
        XCTAssertEqual(FleetWaitStats.coldRestartCost(fiveMinute, pricingTable: PricingTables.anthropic, dayKey: dayKey),
                       3.75, accuracy: 0.0001)
        XCTAssertEqual(FleetWaitStats.coldRestartCost(oneHour, pricingTable: PricingTables.anthropic, dayKey: dayKey),
                       6, accuracy: 0.0001)
        let stats = FleetWaitStats.summarize([fiveMinute, oneHour], dayKey: dayKey, pricingTable: PricingTables.anthropic)
        XCTAssertEqual(stats?.coldRestartCount, 2)
        XCTAssertEqual(stats?.coldRestartCost ?? 0, 9.75, accuracy: 0.0001)
    }

    func testNilOnEmptyAndOpenRowsIgnored() {
        XCTAssertNil(FleetWaitStats.summarize([], dayKey: dayKey, pricingTable: PricingTables.anthropic))
        XCTAssertNil(FleetWaitStats.summarize([wait(start: 0, duration: nil)], dayKey: dayKey,
                                              pricingTable: PricingTables.anthropic))
    }
}

import XCTest
@testable import Claudoscope

/// Tests for the prompt-cache health fold: re-primes, the cold-turn lower
/// bound, the inferred cause rows and the wasted 1h-TTL premium.
///
/// Every figure is derived from per-day and per-model totals, so these fixtures
/// build `DailyContribution` days directly rather than going through the parser.
final class PromptCacheHealthTests: XCTestCase {

    private func day(
        _ date: String,
        read: Int = 0,
        write: Int = 0,
        write1h: Int = 0,
        families: [(String, Int)] = [("opus", 1)]
    ) -> DailyContribution {
        DailyContribution(
            date: date,
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: read,
            cacheCreationTokens: write,
            cacheCreation5mTokens: write - write1h,
            cacheCreation1hTokens: write1h,
            estimatedCost: 0,
            modelBreakdown: families.map {
                ModelDayCost(model: $0.0, inputTokens: 0, outputTokens: 0,
                             cacheReadTokens: 0, estimatedCost: 0, turnCount: $0.1)
            }
        )
    }

    private func session(_ id: String, model: String? = "claude-opus-4-8", days: [DailyContribution]) -> SessionSummary {
        SessionSummary(
            id: id, projectId: "p", slug: nil, title: id,
            firstTimestamp: "", lastTimestamp: "", messageCount: 1, primaryModel: model,
            totalInputTokens: 0, totalOutputTokens: 0,
            totalCacheReadTokens: days.reduce(0) { $0 + $1.cacheReadTokens },
            totalCacheCreationTokens: days.reduce(0) { $0 + $1.cacheCreationTokens },
            totalCacheCreation5mTokens: days.reduce(0) { $0 + $1.cacheCreation5mTokens },
            totalCacheCreation1hTokens: days.reduce(0) { $0 + $1.cacheCreation1hTokens },
            compactionCount: 0, estimatedCost: 0, hasError: false, modelBreakdown: [],
            toolCallCount: 0, observability: .empty, isSubagent: false,
            dailyContributions: days, agentId: nil, spawnedAgentIds: []
        )
    }

    private func health(_ sessions: [SessionSummary]) -> PromptCacheHealth {
        let project = Project(id: "p", name: "P", path: "/tmp/p", sessionCount: sessions.count)
        return AnalyticsEngine.compute(
            sessions: sessions.map { (session: $0, project: project) },
            pricingTable: PricingTables.anthropic,
            from: nil, to: nil
        ).cacheAnalytics.promptCacheHealth
    }

    // MARK: - Re-primes

    func testSingleDaySessionHasNoRePrime() {
        let h = health([session("s1", days: [day("2026-01-01", read: 90_000, write: 10_000)])])
        XCTAssertEqual(h.recachedTokens, 0)
        XCTAssertEqual(h.recachedCost, 0, accuracy: 1e-9)
        XCTAssertTrue(h.inferredMissCauses.isEmpty)
    }

    func testLaterDayWritesCountAsRePrimes() {
        let h = health([session("s1", days: [
            day("2026-01-01", read: 90_000, write: 10_000),
            day("2026-01-02", read: 50_000, write: 8_000),
            day("2026-01-03", read: 50_000, write: 7_000)
        ])])
        XCTAssertEqual(h.recachedTokens, 15_000)
        XCTAssertEqual(h.inferredMissCauses.first?.label, "Resumed the next day")
        XCTAssertEqual(h.inferredMissCauses.first?.sessionCount, 1)
    }

    /// A later day that read from cache but wrote nothing did not re-prime.
    func testLaterDayWithoutWritesIsNotARePrime() {
        let h = health([session("s1", days: [
            day("2026-01-01", read: 90_000, write: 10_000),
            day("2026-01-02", read: 50_000, write: 0)
        ])])
        XCTAssertEqual(h.recachedTokens, 0)
    }

    func testRePrimeCostUsesThe5mWriteRate() {
        let h = health([session("s1", days: [
            day("2026-01-01", write: 10_000),
            day("2026-01-02", write: 1_000_000)
        ])])
        // Opus 4.8 5m cache write is $6.25/MTok.
        XCTAssertEqual(h.recachedCost, 6.25, accuracy: 1e-6)
    }

    // MARK: - Cold turn lower bound

    func testColdTurnsCountOnePerPrimingDayAndFamily() {
        let h = health([session("s1", days: [
            day("2026-01-01", write: 10_000, families: [("opus", 5)]),
            day("2026-01-02", write: 10_000, families: [("opus", 3), ("sonnet", 2)]),
            day("2026-01-03", write: 0, families: [("opus", 4)])   // no write, no prime
        ])])
        XCTAssertEqual(h.coldTurnsLowerBound, 3)
        XCTAssertEqual(h.totalTurns, 14)
        XCTAssertEqual(h.coldTurnShare, 3.0 / 14.0, accuracy: 1e-9)
    }

    func testColdTurnShareIsZeroWithNoTurns() {
        XCTAssertEqual(PromptCacheHealth.empty.coldTurnShare, 0)
    }

    // MARK: - Model switch cause

    func testModelSwitchIsReportedAsACause() {
        let h = health([session("s1", days: [
            day("2026-01-01", write: 12_000, families: [("opus", 4), ("sonnet", 4)])
        ])])
        let cause = h.inferredMissCauses.first { $0.label == "Switched model mid-session" }
        XCTAssertNotNil(cause)
        XCTAssertEqual(cause?.recachedTokens, 6_000, "an even split across two families")
    }

    func testSingleFamilySessionReportsNoModelSwitch() {
        let h = health([session("s1", days: [
            day("2026-01-01", write: 12_000, families: [("opus", 8)])
        ])])
        XCTAssertNil(h.inferredMissCauses.first { $0.label == "Switched model mid-session" })
    }

    // MARK: - Wasted 1h TTL

    func testWasted1hFiresWhenReadsAreBelowWrites() {
        let h = health([session("s1", days: [
            day("2026-01-01", read: 20_000, write: 1_000_000, write1h: 1_000_000)
        ])])
        XCTAssertEqual(h.wasted1hSessions.count, 1)
        // Opus 4.8: $10.00/MTok at 1h vs $6.25 at 5m.
        XCTAssertEqual(h.wasted1hPremium, 3.75, accuracy: 1e-6)
    }

    func testWasted1hSilentWhenTheCacheIsActuallyRead() {
        let h = health([session("s1", days: [
            day("2026-01-01", read: 5_000_000, write: 1_000_000, write1h: 1_000_000)
        ])])
        XCTAssertTrue(h.wasted1hSessions.isEmpty)
        XCTAssertEqual(h.wasted1hPremium, 0, accuracy: 1e-9)
    }

    /// Below the volume floor the premium is pennies and the ratio is noise.
    func testWasted1hSilentBelowTheWriteFloor() {
        let h = health([session("s1", days: [
            day("2026-01-01", read: 0, write: 10_000, write1h: 10_000)
        ])])
        XCTAssertTrue(h.wasted1hSessions.isEmpty)
    }

    /// An unpriced model must not contribute a fabricated premium.
    func testWasted1hSkipsUnpricedModels() {
        let h = health([session("s1", model: "some-unreleased-model", days: [
            day("2026-01-01", read: 0, write: 1_000_000, write1h: 1_000_000)
        ])])
        XCTAssertTrue(h.wasted1hSessions.isEmpty)
        XCTAssertEqual(h.wasted1hPremium, 0, accuracy: 1e-9)
    }

    func testEmptyWhenNothingToReport() {
        let h = health([session("s1", days: [day("2026-01-01", read: 90_000, write: 5_000)])])
        XCTAssertTrue(h.isEmpty)
    }
}

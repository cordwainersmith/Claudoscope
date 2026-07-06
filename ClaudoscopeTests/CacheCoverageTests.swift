import XCTest
@testable import Claudoscope

/// Tests for the Cache Coverage metric: cache_read / (cache_read + cache_write + input),
/// and its relationship to the existing Hit Rate: cache_read / (cache_read + cache_write).
/// Coverage adds plain input tokens to the denominator, so it is always <= Hit Rate and
/// diverges sharply when a turn sends large uncached content.
final class CacheCoverageTests: XCTestCase {

    /// Drives a single-session fixture through the public compute entry point and returns
    /// the resulting cache analytics. Empty pricing table (coverage/hitRatio are
    /// pricing-independent); unbounded window so the fixture day is always in range.
    private func cacheAnalytics(read: Int, write: Int, input: Int) -> CacheAnalytics {
        let day = DailyContribution(
            date: "2026-01-01",
            inputTokens: input,
            outputTokens: 0,
            cacheReadTokens: read,
            cacheCreationTokens: write,
            cacheCreation5mTokens: write,
            cacheCreation1hTokens: 0,
            estimatedCost: 0,
            modelBreakdown: []
        )
        let session = SessionSummary(
            id: "s1", projectId: "p", slug: nil, title: "s1",
            firstTimestamp: "", lastTimestamp: "", messageCount: 1, primaryModel: nil,
            totalInputTokens: input, totalOutputTokens: 0, totalCacheReadTokens: read,
            totalCacheCreationTokens: write, totalCacheCreation5mTokens: write, totalCacheCreation1hTokens: 0,
            compactionCount: 0, estimatedCost: 0, hasError: false, modelBreakdown: [],
            toolCallCount: 0, observability: .empty, isSubagent: false,
            dailyContributions: [day], agentId: nil, spawnedAgentIds: []
        )
        let project = Project(id: "p", name: "P", path: "/tmp/p", sessionCount: 1)
        return AnalyticsEngine.compute(
            sessions: [(session: session, project: project)],
            pricingTable: [:],
            from: nil, to: nil
        ).cacheAnalytics
    }

    func testCoverageBelowHitRateOnTypicalTurn() {
        // Small uncached suffix: the two numbers stay close.
        let c = cacheAnalytics(read: 45_000, write: 3_000, input: 2_000)
        XCTAssertEqual(c.hitRatio, 0.9375, accuracy: 1e-9)          // 45000 / 48000
        XCTAssertEqual(c.cacheCoverage, 0.90, accuracy: 1e-9)       // 45000 / 50000
        XCTAssertLessThanOrEqual(c.cacheCoverage, c.hitRatio)
    }

    func testLargeUncachedInputDivergesCoverageFromHitRate() {
        // A big uncached tool dump after the last breakpoint: Hit Rate is unchanged,
        // Coverage collapses — the case this metric exists to expose.
        let c = cacheAnalytics(read: 45_000, write: 3_000, input: 40_000)
        XCTAssertEqual(c.hitRatio, 0.9375, accuracy: 1e-9)                       // 45000 / 48000
        XCTAssertEqual(c.cacheCoverage, 45_000.0 / 88_000.0, accuracy: 1e-9)     // ~0.5114
        XCTAssertLessThan(c.cacheCoverage, 0.52)
    }

    func testZeroTokensYieldsZeroCoverage() {
        // Denominator guard: no cache and no input must not divide by zero.
        let c = cacheAnalytics(read: 0, write: 0, input: 0)
        XCTAssertEqual(c.cacheCoverage, 0)
        XCTAssertEqual(c.hitRatio, 0)
    }
}

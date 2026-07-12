import XCTest
@testable import Claudoscope

/// SessionSummary blobs persist in the summary cache (SessionSummaryStore).
/// These tests pin the Codable round-trip: a decode that stops matching the
/// encode means cached rows silently degrade into misses (or worse, garbage).
final class SessionSummaryCodableTests: XCTestCase {

    private func roundTrip(_ summary: SessionSummary) throws -> SessionSummary {
        let data = try JSONEncoder().encode(summary)
        return try JSONDecoder().decode(SessionSummary.self, from: data)
    }

    func testRoundTripMaximalSummary() throws {
        let observability = SessionObservability(
            medianTurnDurationMs: 1234.5,
            maxTurnDurationMs: 99999.0,
            dominantEffortLevel: .ultrathink,
            effortDistribution: EffortDistribution(low: 1, medium: 2, high: 3, ultrathink: 4),
            errorClassifications: [.rateLimit, .toolError, .unknown],
            hasIdleZombieGap: true,
            estimatedIdleWasteCost: 0.42,
            compactionTimestamps: ["2026-07-10T10:00:00Z", "2026-07-10T11:00:00Z"],
            parallelToolCallCount: 7,
            maxParallelDegree: 3,
            isWorktreeSession: true
        )
        let day1 = DailyContribution(
            date: "2026-07-10",
            inputTokens: 100, outputTokens: 200, cacheReadTokens: 300,
            cacheCreationTokens: 400, cacheCreation5mTokens: 250, cacheCreation1hTokens: 150,
            estimatedCost: 1.25,
            modelBreakdown: [
                ModelDayCost(model: "fable", inputTokens: 60, outputTokens: 120, cacheReadTokens: 200, estimatedCost: 0.75, turnCount: 2),
                ModelDayCost(model: "haiku", inputTokens: 40, outputTokens: 80, cacheReadTokens: 100, estimatedCost: 0.50, turnCount: 1),
            ]
        )
        let day2 = DailyContribution(
            date: "2026-07-11",
            inputTokens: 10, outputTokens: 20, cacheReadTokens: 30,
            cacheCreationTokens: 40, cacheCreation5mTokens: 40, cacheCreation1hTokens: 0,
            estimatedCost: 0.10,
            modelBreakdown: [
                ModelDayCost(model: "fable", inputTokens: 10, outputTokens: 20, cacheReadTokens: 30, estimatedCost: 0.10, turnCount: 1),
            ]
        )
        let summary = SessionSummary(
            id: "sess-max",
            projectId: "-Users-liranb-projects-Claudoscope",
            slug: "sqlite-cache",
            title: "Add SQLite cache",
            firstTimestamp: "2026-07-10T09:00:00.000Z",
            lastTimestamp: "2026-07-11T18:30:00.000Z",
            messageCount: 42,
            primaryModel: "claude-fable-5",
            totalInputTokens: 110,
            totalOutputTokens: 220,
            totalCacheReadTokens: 330,
            totalCacheCreationTokens: 440,
            totalCacheCreation5mTokens: 290,
            totalCacheCreation1hTokens: 150,
            compactionCount: 2,
            estimatedCost: 1.35,
            hasError: true,
            modelBreakdown: [
                ModelTokenBreakdown(model: "fable", inputTokens: 70, outputTokens: 140, cacheReadTokens: 230, estimatedCost: 0.85, turnCount: 3),
                ModelTokenBreakdown(model: "haiku", inputTokens: 40, outputTokens: 80, cacheReadTokens: 100, estimatedCost: 0.50, turnCount: 1),
            ],
            toolCallCount: 17,
            observability: observability,
            isSubagent: true,
            dailyContributions: [day1, day2],
            isCowork: true,
            agentId: "abc123",
            spawnedAgentIds: ["child-1", "child-2"]
        )

        XCTAssertEqual(try roundTrip(summary), summary)
    }

    func testRoundTripMinimalSummary() throws {
        let summary = SessionSummary(
            id: "sess-min",
            projectId: "unknown",
            slug: nil,
            title: "sess-min",
            firstTimestamp: "",
            lastTimestamp: "",
            messageCount: 0,
            primaryModel: nil,
            totalInputTokens: 0,
            totalOutputTokens: 0,
            totalCacheReadTokens: 0,
            totalCacheCreationTokens: 0,
            totalCacheCreation5mTokens: 0,
            totalCacheCreation1hTokens: 0,
            compactionCount: 0,
            estimatedCost: 0,
            hasError: false,
            modelBreakdown: [],
            toolCallCount: 0,
            observability: .empty,
            isSubagent: false,
            dailyContributions: []
        )
        XCTAssertEqual(try roundTrip(summary), summary)
    }
}

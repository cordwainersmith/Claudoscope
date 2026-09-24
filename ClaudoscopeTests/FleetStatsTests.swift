import XCTest
@testable import Claudoscope

final class FleetStatsTests: XCTestCase {
    private let now = ISO8601.parse("2026-09-23T12:00:00.000Z")!

    private func agent(first: String, last: String, cost: Double = 0, live: Bool = false,
                       input: Int = 0, cacheRead: Int = 0, cacheCreate: Int = 0,
                       days: [DailyContribution] = []) -> FleetAgent {
        let summary = SessionSummary(
            id: UUID().uuidString, projectId: "-p", slug: nil, title: "t",
            firstTimestamp: first, lastTimestamp: last, messageCount: 1, primaryModel: nil,
            totalInputTokens: input, totalOutputTokens: 0, totalCacheReadTokens: cacheRead,
            totalCacheCreationTokens: cacheCreate, totalCacheCreation5mTokens: 0,
            totalCacheCreation1hTokens: 0, compactionCount: 0, estimatedCost: cost,
            hasError: false, modelBreakdown: [], toolCallCount: 0,
            observability: .empty, isSubagent: false, dailyContributions: days
        )
        return FleetAgent(summary: summary, registry: nil, state: .working,
                          since: ISO8601.parse(last)!, isLive: live, isBackgroundJob: false, isBypass: false)
    }

    private func day(_ date: String, _ cost: Double) -> DailyContribution {
        DailyContribution(date: date, inputTokens: 0, outputTokens: 0, cacheReadTokens: 0,
                          cacheCreationTokens: 0, cacheCreation5mTokens: 0, cacheCreation1hTokens: 0,
                          estimatedCost: cost, modelBreakdown: [])
    }

    func testBurnRateUsesNowForLiveAndLastForLanded() {
        let live = agent(first: "2026-09-23T10:00:00.000Z", last: "2026-09-23T11:00:00.000Z", cost: 10, live: true)
        XCTAssertEqual(live.burnRatePerHour(now: now)!, 5, accuracy: 0.001)
        let landed = agent(first: "2026-09-23T10:00:00.000Z", last: "2026-09-23T11:00:00.000Z", cost: 10)
        XCTAssertEqual(landed.burnRatePerHour(now: now)!, 10, accuracy: 0.001)
    }

    func testBurnRateNilForYoungOrFreeSessions() {
        XCTAssertNil(agent(first: "2026-09-23T11:58:00.000Z", last: "2026-09-23T11:59:00.000Z", cost: 3, live: true)
            .burnRatePerHour(now: now))
        XCTAssertNil(agent(first: "2026-09-23T10:00:00.000Z", last: "2026-09-23T11:00:00.000Z", live: true)
            .burnRatePerHour(now: now))
    }

    func testCacheHitRate() {
        XCTAssertEqual(agent(first: "2026-09-23T10:00:00.000Z", last: "2026-09-23T11:00:00.000Z",
                             input: 10, cacheRead: 80, cacheCreate: 10).cacheHitRate!, 0.8, accuracy: 0.0001)
        XCTAssertNil(agent(first: "2026-09-23T10:00:00.000Z", last: "2026-09-23T11:00:00.000Z").cacheHitRate)
    }

    func testHourlyConcurrencyBuckets() {
        let agents = [
            agent(first: "2026-09-23T09:30:00.000Z", last: "2026-09-23T10:30:00.000Z"),   // 09-10, 10-11
            agent(first: "2026-09-23T11:15:00.000Z", last: "2026-09-23T11:20:00.000Z", live: true), // 11-12
        ]
        let counts = FleetStateEngine.hourlyConcurrency(agents, now: now, hours: 4)
        XCTAssertEqual(counts, [0, 1, 1, 1])
    }

    func testSpendOnDaySumsOnlyToday() {
        let today = ISO8601.localDayKey(for: now)
        let agents = [
            agent(first: "2026-09-22T10:00:00.000Z", last: "2026-09-23T11:00:00.000Z",
                  days: [day("2000-01-01", 50), day(today, 2)]),
            agent(first: "2026-09-23T10:00:00.000Z", last: "2026-09-23T11:00:00.000Z", days: [day(today, 1.5)]),
        ]
        XCTAssertEqual(FleetStateEngine.spendOnDay(agents, now: now), 3.5, accuracy: 0.0001)
    }

    func testShortToolTarget() {
        XCTAssertEqual(SessionParser.shortToolTarget("/Users/x/proj/Claudoscope/Store/SessionStore.swift"), "SessionStore.swift")
        XCTAssertEqual(SessionParser.shortToolTarget("swift build\nswift test"), "swift build")
        XCTAssertEqual(SessionParser.shortToolTarget(String(repeating: "a", count: 200)).count, 80)
    }

    func testParserCapturesLatestTurn() async throws {
        let lines = [
            #"{"type":"last-prompt","lastPrompt":"fix the gauge\nplease","sessionId":"s"}"#,
            #"{"type":"assistant","uuid":"u1","sessionId":"s","timestamp":"2026-09-23T10:00:00.000Z","message":{"role":"assistant","id":"m1","model":"claude-sonnet-4-5","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/a/b/First.swift"}}],"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":1000,"cache_creation_input_tokens":90}}}"#,
            #"{"type":"assistant","uuid":"u2","sessionId":"s","timestamp":"2026-09-23T10:01:00.000Z","message":{"role":"assistant","id":"m2","model":"claude-sonnet-4-5","stop_reason":"tool_use","content":[{"type":"text","text":"ok"},{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"swift test --filter Fleet\nls","description":"run tests"}}],"usage":{"input_tokens":20,"output_tokens":5,"cache_read_input_tokens":150000,"cache_creation_input_tokens":0}}}"#,
            #"{"type":"assistant","uuid":"u3","sessionId":"s","timestamp":"2026-09-23T10:02:00.000Z","message":{"role":"assistant","id":"m3","model":"claude-sonnet-4-5","stop_reason":"end_turn","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":30,"output_tokens":5,"cache_read_input_tokens":160000,"cache_creation_input_tokens":0}}}"#,
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fleet-latest-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = try await SessionParser().parseMetadata(url: url, sessionId: "s", pricingTable: PricingTables.anthropic)
        let turn = try XCTUnwrap(summary.latestTurn)
        XCTAssertEqual(turn.contextTokens, 160_030)
        XCTAssertEqual(turn.contextWindowTokens, ContextWindow.standard)
        XCTAssertEqual(turn.toolName, "Bash")
        XCTAssertEqual(turn.toolTarget, "swift test --filter Fleet")
        XCTAssertEqual(turn.toolTimestamp, "2026-09-23T10:01:00.000Z")
        XCTAssertEqual(turn.turnTimestamp, "2026-09-23T10:02:00.000Z")
        // The last turn only read cache; the tier comes from the first turn's write.
        XCTAssertEqual(turn.cacheTTLSeconds, 300)
        XCTAssertEqual(turn.lastPrompt, "fix the gauge")
    }
}

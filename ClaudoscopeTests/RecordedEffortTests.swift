import XCTest
@testable import Claudoscope

/// Claude Code 2.1.29x+ records `effort`, `perTurnEffort`, `requestedModel` and
/// `thinkingDurationMs` on assistant records. Recorded effort replaces the
/// thinking/output heuristic; older records fall back to it and are counted as
/// estimated.
final class RecordedEffortTests: XCTestCase {

    private let table = PricingTables.anthropic

    private func write(_ lines: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-effort-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sess-1.jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// One billed assistant record: 1000 in + 2000 out on Sonnet 4.6 = $0.033.
    /// 2000 output tokens alone make the heuristic say `.xhigh`.
    private func assistant(
        _ id: String,
        effort: String? = nil,
        perTurnEffort: String? = nil,
        requestedModel: String? = nil,
        model: String = "claude-sonnet-4-6",
        thinkingMs: Int? = nil,
        output: Int = 2000,
        timestamp: String = "2026-11-01T10:00:00.000Z"
    ) -> String {
        var obj: [String: Any] = [
            "type": "assistant",
            "uuid": "u-\(id)",
            "sessionId": "sess-1",
            "timestamp": timestamp,
            "message": [
                "role": "assistant",
                "id": "msg-\(id)",
                "stop_reason": "end_turn",
                "model": model,
                "usage": ["input_tokens": 1000, "output_tokens": output],
            ] as [String: Any],
        ]
        if let effort { obj["effort"] = effort }
        if let perTurnEffort { obj["perTurnEffort"] = perTurnEffort }
        if let requestedModel { obj["requestedModel"] = requestedModel }
        if let thinkingMs { obj["thinkingDurationMs"] = thinkingMs }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }

    private func summary(_ lines: [String]) async throws -> SessionSummary {
        try await SessionParser().parseMetadata(url: try write(lines), sessionId: "sess-1", pricingTable: table)
    }

    // MARK: - Recorded vs estimated

    func testRecordedEffortBeatsHeuristic() async throws {
        let s = try await summary([assistant("1", effort: "medium")])
        let dist = s.observability.effortDistribution
        XCTAssertEqual(dist.medium, 1)
        XCTAssertEqual(dist.xhigh, 0, "heuristic would say xhigh for 2000 output tokens")
        XCTAssertEqual(dist.estimatedTurns, 0)
        XCTAssertEqual(s.observability.dominantEffortLevel, .medium)
    }

    func testPerTurnEffortOverridesSessionEffort() async throws {
        let s = try await summary([assistant("1", effort: "medium", perTurnEffort: "xhigh")])
        XCTAssertEqual(s.observability.effortDistribution.xhigh, 1)
        XCTAssertEqual(s.observability.effortDistribution.medium, 0)
    }

    func testMissingFieldFallsBackToHeuristicAndCountsAsEstimated() async throws {
        let s = try await summary([assistant("1")])
        XCTAssertEqual(s.observability.effortDistribution.xhigh, 1)
        XCTAssertEqual(s.observability.effortDistribution.estimatedTurns, 1)
        let day = try XCTUnwrap(s.dailyContributions.first?.effortBreakdown?.first)
        XCTAssertEqual(day.estimatedTurnCount, 1)
    }

    func testUnknownRecordedValueFallsBack() async throws {
        let s = try await summary([assistant("1", effort: "ultra", output: 100)])
        XCTAssertEqual(s.observability.effortDistribution.medium, 1)
        XCTAssertEqual(s.observability.effortDistribution.estimatedTurns, 1)
    }

    func testRecordedEffortHelper() {
        XCTAssertEqual(ObservabilityAnalyzer.recordedEffort(effort: "max", perTurnEffort: nil), .max)
        XCTAssertEqual(ObservabilityAnalyzer.recordedEffort(effort: "low", perTurnEffort: "high"), .high)
        XCTAssertEqual(ObservabilityAnalyzer.recordedEffort(effort: "low", perTurnEffort: "bogus"), .low)
        XCTAssertNil(ObservabilityAnalyzer.recordedEffort(effort: nil, perTurnEffort: nil))
    }

    // MARK: - Per-day effort cost

    func testEffortBreakdownPartitionsSessionCost() async throws {
        let s = try await summary([
            assistant("1", effort: "medium", thinkingMs: 1000),
            assistant("2", effort: "high", thinkingMs: 3000, timestamp: "2026-11-01T10:01:00.000Z"),
            assistant("3", effort: "high", timestamp: "2026-11-01T10:02:00.000Z"),
        ])
        let rows = try XCTUnwrap(s.dailyContributions.first?.effortBreakdown)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.estimatedCost }, s.estimatedCost, accuracy: 1e-9)
        let high = try XCTUnwrap(rows.first { $0.level == .high })
        XCTAssertEqual(high.turnCount, 2)
        XCTAssertEqual(high.thinkingDurationMs, 3000)
        XCTAssertEqual(high.estimatedCost, 0.066, accuracy: 1e-9)
    }

    func testEffortAnalyticsSplitsCostPerTurn() async throws {
        let s = try await summary([
            assistant("1", effort: "medium", thinkingMs: 2000),
            assistant("2", effort: "high", timestamp: "2026-11-01T10:01:00.000Z"),
        ])
        let project = Project(id: "p", name: "p", path: "/p", sessionCount: 1)
        let data = AnalyticsEngine.compute(sessions: [(s, project)], pricingTable: table)
        let effort = data.effortAnalytics
        XCTAssertEqual(effort.distribution.total, 2)
        let medium = try XCTUnwrap(effort.costByEffort.first { $0.level == .medium })
        XCTAssertEqual(medium.turnCount, 1)
        XCTAssertEqual(medium.totalCost, 0.033, accuracy: 1e-9)
        XCTAssertEqual(medium.avgThinkingMs ?? 0, 2000, accuracy: 0.1)
        XCTAssertNil(effort.costByEffort.first { $0.level == .high }?.avgThinkingMs)
        XCTAssertEqual(medium.estimatedShare, 0)
    }

    // MARK: - Model fallbacks

    func testCanonicalModelId() {
        XCTAssertEqual(canonicalModelId("claude-opus-5-5[1m]"), canonicalModelId("claude-opus-5-5"))
        XCTAssertEqual(canonicalModelId("claude-haiku-4-5@20251001"), canonicalModelId("claude-haiku-4-5-20251001"))
        XCTAssertEqual(canonicalModelId("claude-haiku-4-5@20251001"), "claude-haiku-4-5")
        XCTAssertEqual(canonicalModelId("Claude-Sonnet-5"), "claude-sonnet-5")
        XCTAssertNotEqual(canonicalModelId("claude-opus-5-5"), canonicalModelId("claude-opus-4-8"))
    }

    func testFallbackCountedOnlyForRealSwitch() async throws {
        let s = try await summary([
            assistant("1", requestedModel: "claude-opus-5-5[1m]", model: "claude-opus-5-5"),
            assistant("2", requestedModel: "claude-haiku-4-5@20251001", model: "claude-haiku-4-5-20251001",
                      timestamp: "2026-11-01T10:01:00.000Z"),
            assistant("3", requestedModel: "claude-opus-5-5", model: "claude-opus-4-8",
                      timestamp: "2026-11-01T10:02:00.000Z"),
            assistant("4", requestedModel: "claude-opus-5-5", model: "claude-opus-4-8",
                      timestamp: "2026-11-01T10:03:00.000Z"),
        ])
        XCTAssertEqual(s.modelFallbacks, [ModelFallback(requested: "claude-opus-5-5", served: "claude-opus-4-8", count: 2)])
    }

    func testNoFallbacksIsNil() async throws {
        let s = try await summary([assistant("1", requestedModel: "claude-sonnet-4-6")])
        XCTAssertNil(s.modelFallbacks)
    }

    // MARK: - Cache blobs

    func testSummaryWithNewFieldsRoundTrips() async throws {
        let s = try await summary([
            assistant("1", effort: "high", requestedModel: "claude-opus-5-5", model: "claude-opus-4-8", thinkingMs: 500),
        ])
        let decoded = try JSONDecoder().decode(SessionSummary.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(decoded, s)
        XCTAssertNotNil(decoded.dailyContributions.first?.effortBreakdown)
    }

    func testLegacyDailyContributionWithoutEffortDecodes() throws {
        let json = #"{"date":"2026-11-01","inputTokens":1,"outputTokens":2,"cacheReadTokens":0,"cacheCreationTokens":0,"cacheCreation5mTokens":0,"cacheCreation1hTokens":0,"estimatedCost":0.1,"modelBreakdown":[]}"#
        let day = try JSONDecoder().decode(DailyContribution.self, from: Data(json.utf8))
        XCTAssertNil(day.effortBreakdown)
        XCTAssertNil(day.permissionStats)
    }
}

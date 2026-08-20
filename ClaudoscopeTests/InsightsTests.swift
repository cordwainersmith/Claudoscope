import XCTest
@testable import Claudoscope

/// Facet/session-meta decoding (snake_case, lenient enums), the InsightsEngine
/// join against parsed sessions, and InsightsService empty-dir behavior.
final class InsightsTests: XCTestCase {

    private let facetJSON = """
    {"underlying_goal":"Fix the login bug","goal_categories":{"bug_fix":2},
     "outcome":"mostly_achieved","user_satisfaction_counts":{"likely_satisfied":1},
     "claude_helpfulness":"very_helpful","session_type":"single_task",
     "friction_counts":{"buggy_code":1,"wrong_approach":2},"friction_detail":"one regression",
     "primary_success":"multi_file_changes","brief_summary":"Fixed login.",
     "session_id":"sess-1"}
    """

    // MARK: - Decoding

    func testFacetDecodesSnakeCase() throws {
        let facet = try JSONDecoder().decode(SessionFacet.self, from: Data(facetJSON.utf8))
        XCTAssertEqual(facet.sessionId, "sess-1")
        XCTAssertEqual(facet.underlyingGoal, "Fix the login bug")
        XCTAssertEqual(facet.outcome, .mostlyAchieved)
        XCTAssertEqual(facet.goalCategories?["bug_fix"], 2)
        XCTAssertEqual(facet.frictionTotal, 3)
        XCTAssertEqual(facet.primarySuccess, "multi_file_changes")
    }

    func testUnknownOutcomeFallsToUnclear() throws {
        let json = facetJSON.replacingOccurrences(of: "mostly_achieved", with: "some_future_value")
        let facet = try JSONDecoder().decode(SessionFacet.self, from: Data(json.utf8))
        XCTAssertEqual(facet.outcome, .unclear)
    }

    func testSessionMetaDecodes() throws {
        let json = """
        {"session_id":"sess-1","project_path":"/Users/x/proj","start_time":"2026-03-01T10:00:00Z",
         "duration_minutes":42.5,"first_prompt":"fix it","user_interruptions":3,"tool_errors":1,
         "lines_added":120,"lines_removed":30,"files_modified":5,"languages":{},"git_commits":2}
        """
        let meta = try JSONDecoder().decode(SessionMetaFacet.self, from: Data(json.utf8))
        XCTAssertEqual(meta.durationMinutes, 42.5)
        XCTAssertEqual(meta.linesAdded, 120)
        XCTAssertEqual(meta.userInterruptions, 3)
    }

    // MARK: - Engine

    private func facet(id: String, outcome: String, friction: [String: Int] = [:]) throws -> SessionFacet {
        var json = facetJSON
            .replacingOccurrences(of: "sess-1", with: id)
            .replacingOccurrences(of: "mostly_achieved", with: outcome)
        let frictionJSON = friction.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
        json = json.replacingOccurrences(
            of: "{\"buggy_code\":1,\"wrong_approach\":2}", with: "{\(frictionJSON)}"
        )
        return try JSONDecoder().decode(SessionFacet.self, from: Data(json.utf8))
    }

    private func summary(id: String, cost: Double) -> SessionSummary {
        SessionSummary(
            id: id, projectId: "p", slug: nil, title: "t-\(id)",
            firstTimestamp: "", lastTimestamp: "", messageCount: 1, primaryModel: nil,
            totalInputTokens: 0, totalOutputTokens: 0, totalCacheReadTokens: 0,
            totalCacheCreationTokens: 0, totalCacheCreation5mTokens: 0,
            totalCacheCreation1hTokens: 0, compactionCount: 0, estimatedCost: cost,
            hasError: false, modelBreakdown: [], toolCallCount: 0,
            observability: .empty, isSubagent: false, dailyContributions: []
        )
    }

    func testEngineJoinsAndAggregates() throws {
        let facets = [
            (facet: try facet(id: "a", outcome: "fully_achieved", friction: ["buggy_code": 2]), fileDate: Date(timeIntervalSince1970: 100) as Date?),
            (facet: try facet(id: "b", outcome: "fully_achieved"), fileDate: Date(timeIntervalSince1970: 200) as Date?),
            (facet: try facet(id: "orphan", outcome: "not_achieved", friction: ["buggy_code": 1]), fileDate: nil),
        ]
        let data = InsightsEngine.build(
            facets: facets,
            meta: [:],
            summariesById: ["a": summary(id: "a", cost: 1.5), "b": summary(id: "b", cost: 0.5)],
            storeSessionCount: 10
        )

        XCTAssertEqual(data.insights.count, 3, "unjoined facets are kept")
        XCTAssertNotNil(data.insights.first { $0.id == "a" }?.summary)
        XCTAssertNil(data.insights.first { $0.id == "orphan" }?.summary)

        XCTAssertEqual(data.outcomeDistribution.count, 2)
        XCTAssertEqual(data.outcomeDistribution.first?.outcome, .fullyAchieved)
        XCTAssertEqual(data.outcomeDistribution.first?.count, 2)

        XCTAssertEqual(data.frictionTotals.count, 1)
        XCTAssertEqual(data.frictionTotals.first?.kind, "buggy_code")
        XCTAssertEqual(data.frictionTotals.first?.count, 3)

        XCTAssertEqual(data.coverage.facetCount, 3)
        XCTAssertEqual(data.coverage.storeSessionCount, 10)
        XCTAssertEqual(data.coverage.latestFacetDate, Date(timeIntervalSince1970: 200))
    }

    // MARK: - Service

    func testMissingDirsReturnEmpty() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-insights-\(UUID().uuidString)")
        let service = InsightsService(claudeDir: dir)
        let facets = await service.loadFacets()
        XCTAssertTrue(facets.isEmpty)
        let meta = await service.loadMeta(sessionIds: ["x"])
        XCTAssertTrue(meta.isEmpty)
    }

    func testServiceLoadsFacetAndMeta() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-insights-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let facetsDir = dir.appendingPathComponent("usage-data/facets")
        let metaDir = dir.appendingPathComponent("usage-data/session-meta")
        try FileManager.default.createDirectory(at: facetsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metaDir, withIntermediateDirectories: true)
        try facetJSON.write(to: facetsDir.appendingPathComponent("sess-1.json"), atomically: true, encoding: .utf8)
        try "garbage".write(to: facetsDir.appendingPathComponent("bad.json"), atomically: true, encoding: .utf8)
        try "{\"session_id\":\"sess-1\",\"duration_minutes\":10}".write(
            to: metaDir.appendingPathComponent("sess-1.json"), atomically: true, encoding: .utf8
        )

        let service = InsightsService(claudeDir: dir)
        let facets = await service.loadFacets()
        XCTAssertEqual(facets.count, 1, "malformed facet files are skipped")
        XCTAssertEqual(facets.first?.facet.sessionId, "sess-1")
        XCTAssertNotNil(facets.first?.fileDate)

        let meta = await service.loadMeta(sessionIds: ["sess-1", "missing"])
        XCTAssertEqual(meta.count, 1)
        XCTAssertEqual(meta["sess-1"]?.durationMinutes, 10)
    }
}

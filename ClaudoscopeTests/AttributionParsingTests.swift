import XCTest
@testable import Claudoscope

/// Tests for the per-record cost attribution Claude Code stamps on billed
/// assistant records (2.1.24x+): `attributionSkill`, `attributionMcpServer` +
/// `attributionMcpTool`, `attributionAgent`, and `sessionKind`.
///
/// The load-bearing property throughout is that skill and MCP attribution are
/// INDEPENDENT partial partitions. A single record can carry both tags, so
/// neither sums to session cost and the two sums together can exceed it.
final class AttributionParsingTests: XCTestCase {

    private let table = PricingTables.anthropic

    private func writeTempFile(_ lines: [String], name: String = "session") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-attr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// One billed assistant record. 1000 input + 2000 output on Sonnet 4.6
    /// ($3/$15) = $0.003 + $0.030 = $0.033.
    private func record(
        uuid: String,
        msgId: String,
        timestamp: String = "2026-09-10T10:00:00.000Z",
        skill: String? = nil,
        mcpServer: String? = nil,
        mcpTool: String? = nil,
        sessionKind: String? = nil,
        agent: String? = nil,
        isSidechain: Bool = false,
        input: Int = 1000,
        output: Int = 2000
    ) -> String {
        var obj: [String: Any] = [
            "type": "assistant",
            "uuid": uuid,
            "sessionId": "sess-1",
            "timestamp": timestamp,
            "isSidechain": isSidechain,
            "message": [
                "role": "assistant",
                "id": msgId,
                "stop_reason": "end_turn",
                "model": "claude-sonnet-4-6",
                "usage": ["input_tokens": input, "output_tokens": output, "service_tier": "standard"],
            ] as [String: Any],
        ]
        if let skill { obj["attributionSkill"] = skill }
        if let mcpServer { obj["attributionMcpServer"] = mcpServer }
        if let mcpTool { obj["attributionMcpTool"] = mcpTool }
        if let sessionKind { obj["sessionKind"] = sessionKind }
        if let agent { obj["attributionAgent"] = agent }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }

    private let perRecordCost = 0.033

    // MARK: - Skill attribution

    func testSkillTaggedRecordIsAttributed() async throws {
        let url = try writeTempFile([record(uuid: "u1", msgId: "m1", skill: "dataviz")])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let s = try await SessionParser().parseMetadata(url: url, sessionId: "sess-1", pricingTable: table)
        XCTAssertEqual(s.skillBreakdown?.count, 1)
        let row = try XCTUnwrap(s.skillBreakdown?.first)
        XCTAssertEqual(row.skill, "dataviz")
        XCTAssertEqual(row.turnCount, 1)
        XCTAssertEqual(row.estimatedCost, perRecordCost, accuracy: 1e-9)
        XCTAssertEqual(row.inputTokens, 1000)
        XCTAssertEqual(row.outputTokens, 2000)
    }

    /// Tags arrive both bare and plugin-qualified. The parser stores them raw;
    /// normalizing is the engine's job, so both must survive as distinct rows.
    func testBareAndQualifiedSkillTagsAreStoredRaw() async throws {
        let url = try writeTempFile([
            record(uuid: "u1", msgId: "m1", skill: "frontend-design"),
            record(uuid: "u2", msgId: "m2", skill: "frontend-design:frontend-design"),
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let s = try await SessionParser().parseMetadata(url: url, sessionId: "sess-1", pricingTable: table)
        XCTAssertEqual(Set((s.skillBreakdown ?? []).map(\.skill)),
                       ["frontend-design", "frontend-design:frontend-design"])
    }

    // MARK: - MCP attribution

    func testMcpTaggedRecordKeepsServerAndToolSeparate() async throws {
        let url = try writeTempFile([
            record(uuid: "u1", msgId: "m1", mcpServer: "marketo-lead-activity", mcpTool: "list_leads"),
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let s = try await SessionParser().parseMetadata(url: url, sessionId: "sess-1", pricingTable: table)
        let row = try XCTUnwrap(s.mcpBreakdown?.first)
        XCTAssertEqual(row.server, "marketo-lead-activity")
        XCTAssertEqual(row.tool, "list_leads")
        XCTAssertEqual(row.id, "marketo-lead-activity/list_leads")
        XCTAssertEqual(row.estimatedCost, perRecordCost, accuracy: 1e-9)
    }

    // MARK: - Independence

    /// The corpus has 1517 messages carrying BOTH tags. Such a record must be
    /// counted in full under each dimension, which is exactly why the two sums
    /// can exceed session cost and each needs its own remainder.
    func testRecordWithBothTagsCountsFullyInEachDimension() async throws {
        let url = try writeTempFile([
            record(uuid: "u1", msgId: "m1", skill: "claude-api", mcpServer: "jfrog-docs", mcpTool: "fetch"),
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let s = try await SessionParser().parseMetadata(url: url, sessionId: "sess-1", pricingTable: table)
        XCTAssertEqual(s.skillBreakdown?.first?.estimatedCost ?? 0, perRecordCost, accuracy: 1e-9)
        XCTAssertEqual(s.mcpBreakdown?.first?.estimatedCost ?? 0, perRecordCost, accuracy: 1e-9)
        XCTAssertEqual(s.estimatedCost, perRecordCost, accuracy: 1e-9)

        // The two partitions together exceed the total. This is correct, not a bug.
        let skillSum = (s.skillBreakdown ?? []).reduce(0) { $0 + $1.estimatedCost }
        let mcpSum = (s.mcpBreakdown ?? []).reduce(0) { $0 + $1.estimatedCost }
        XCTAssertGreaterThan(skillSum + mcpSum, s.estimatedCost)
    }

    /// Each partition is individually bounded by the total.
    func testPartialPartitionsNeverExceedTotalIndividually() async throws {
        let url = try writeTempFile([
            record(uuid: "u1", msgId: "m1", skill: "ship"),
            record(uuid: "u2", msgId: "m2", mcpServer: "srv", mcpTool: "tool"),
            record(uuid: "u3", msgId: "m3"),
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let s = try await SessionParser().parseMetadata(url: url, sessionId: "sess-1", pricingTable: table)
        let skillSum = (s.skillBreakdown ?? []).reduce(0) { $0 + $1.estimatedCost }
        let mcpSum = (s.mcpBreakdown ?? []).reduce(0) { $0 + $1.estimatedCost }
        XCTAssertLessThanOrEqual(skillSum, s.estimatedCost + 1e-9)
        XCTAssertLessThanOrEqual(mcpSum, s.estimatedCost + 1e-9)
        // One of three records was untagged, so each remainder is non-zero.
        XCTAssertGreaterThan(s.estimatedCost - skillSum, 0)
        XCTAssertGreaterThan(s.estimatedCost - mcpSum, 0)
    }

    // MARK: - Scalars

    func testSessionKindIsCapturedAsScalar() async throws {
        let url = try writeTempFile([
            record(uuid: "u1", msgId: "m1", sessionKind: "bg"),
            record(uuid: "u2", msgId: "m2", sessionKind: "bg"),
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let s = try await SessionParser().parseMetadata(url: url, sessionId: "sess-1", pricingTable: table)
        XCTAssertEqual(s.sessionKind, "bg")
    }

    /// attributionAgent carries one value for a whole subagent file, so five
    /// tagged records must collapse to one scalar, not a five-row breakdown.
    func testAttributionAgentCollapsesToOneScalar() async throws {
        let lines = (1...5).map {
            record(uuid: "u\($0)", msgId: "m\($0)", agent: "Explore", isSidechain: true)
        }
        let url = try writeTempFile(lines, name: "agent-abc123")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let s = try await SessionParser().parseMetadata(url: url, sessionId: "sess-1", pricingTable: table)
        XCTAssertEqual(s.attributionAgent, "Explore")
    }

    func testUntaggedSessionHasEmptyBreakdowns() async throws {
        let url = try writeTempFile([record(uuid: "u1", msgId: "m1")])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let s = try await SessionParser().parseMetadata(url: url, sessionId: "sess-1", pricingTable: table)
        XCTAssertEqual(s.skillBreakdown ?? [], [])
        XCTAssertEqual(s.mcpBreakdown ?? [], [])
        XCTAssertNil(s.attributionAgent)
        XCTAssertNil(s.sessionKind)
    }

    // MARK: - Streaming blocks

    /// `apiBlockIndex` is the streaming content-block ordinal inside ONE API
    /// response, not a billing window: a single message can emit 20+ records
    /// that all repeat the same cumulative usage and the same attribution tag.
    /// Message-id dedup must bill that once and produce turnCount == 1.
    ///
    /// No production code handles this specially; the test exists to keep it
    /// that way, because double-billing here would silently inflate every
    /// attributed skill by the streaming block count.
    func testStreamedBlocksOfOneMessageBillOnce() async throws {
        let lines = (0..<22).map { i in
            var obj: [String: Any] = [
                "type": "assistant",
                "uuid": "u\(i)",
                "sessionId": "sess-1",
                "timestamp": "2026-09-10T10:00:0\(i % 10).000Z",
                "apiBlockIndex": i,
                "attributionSkill": "dataviz",
                "message": [
                    "role": "assistant",
                    "id": "msg_stream",
                    "stop_reason": "end_turn",
                    "model": "claude-sonnet-4-6",
                    "usage": ["input_tokens": 1000, "output_tokens": 2000, "service_tier": "standard"],
                ] as [String: Any],
            ]
            obj["isSidechain"] = false
            return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
        }
        let url = try writeTempFile(lines)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let s = try await SessionParser().parseMetadata(url: url, sessionId: "sess-1", pricingTable: table)
        let row = try XCTUnwrap(s.skillBreakdown?.first)
        XCTAssertEqual(row.turnCount, 1, "22 streamed blocks of one message must bill as one turn")
        XCTAssertEqual(row.estimatedCost, perRecordCost, accuracy: 1e-9)
        XCTAssertEqual(s.estimatedCost, perRecordCost, accuracy: 1e-9)
    }

    // MARK: - Per-day windowing

    /// Attribution lives inside dailyContributions so date-windowed analytics
    /// stay correct for a /resume'd session. The session rollup must equal the
    /// sum of the per-day rows.
    func testAttributionIsSplitPerDayAndRollupMatches() async throws {
        let url = try writeTempFile([
            record(uuid: "u1", msgId: "m1", timestamp: "2026-09-10T10:00:00.000Z", skill: "ship"),
            record(uuid: "u2", msgId: "m2", timestamp: "2026-09-12T10:00:00.000Z", skill: "ship"),
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let s = try await SessionParser().parseMetadata(url: url, sessionId: "sess-1", pricingTable: table)
        XCTAssertEqual(s.dailyContributions.count, 2)
        for day in s.dailyContributions {
            XCTAssertEqual(day.skillBreakdown?.count, 1)
            XCTAssertEqual(day.skillBreakdown?.first?.turnCount, 1)
        }
        let perDaySum = s.dailyContributions
            .flatMap { $0.skillBreakdown ?? [] }
            .reduce(0) { $0 + $1.estimatedCost }
        let rollup = try XCTUnwrap(s.skillBreakdown?.first)
        XCTAssertEqual(rollup.estimatedCost, perDaySum, accuracy: 1e-9)
        XCTAssertEqual(rollup.turnCount, 2)
    }
}

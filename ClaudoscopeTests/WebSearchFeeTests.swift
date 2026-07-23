import XCTest
@testable import Claudoscope

/// Web-search request fee ($0.01 per search). The count is read from
/// `toolUseResult.searchCount` on WebSearch tool-result records, NOT from
/// `usage.server_tool_use.web_search_requests` (always 0 in Claude Code
/// transcripts, verified on Vertex). The server-side web-search content tokens
/// are not recorded in the transcript and are intentionally not billed.
final class WebSearchFeeTests: XCTestCase {

    private let table = PricingTables.anthropic
    /// sonnet: 1000 in @ $3/MTok + 2000 out @ $15/MTok = 0.033.
    private let expectedTokenCost = 0.003 + 0.030
    private let fee = 0.01

    private func writeTempFile(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-websearch-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A billed assistant record (stop_reason present so it counts once). This is
    /// the turn that issues the WebSearch tool call; the fee attributes to it.
    private func assistantRecord(
        msgId: String = "m1",
        speed: String? = nil,
        input: Int = 1000,
        output: Int = 2000
    ) -> String {
        let speedField = speed.map { "\"speed\":\"\($0)\"," } ?? ""
        return "{\"type\":\"assistant\",\"uuid\":\"\(UUID().uuidString)\",\"sessionId\":\"sess-1\",\"timestamp\":\"2026-04-26T10:00:00.000Z\",\"message\":{\"role\":\"assistant\",\"id\":\"\(msgId)\",\"stop_reason\":\"tool_use\",\"model\":\"claude-sonnet-4-6\",\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\(speedField)\"service_tier\":\"standard\"}}}"
    }

    /// A WebSearch tool-result record carrying the search count.
    private func searchResultRecord(searchCount: Int, uuid: String = UUID().uuidString) -> String {
        return "{\"type\":\"user\",\"uuid\":\"\(uuid)\",\"sessionId\":\"sess-1\",\"timestamp\":\"2026-04-26T10:00:01.000Z\",\"toolUseResult\":{\"tool_use_id\":\"tu1\",\"query\":\"q\",\"searchCount\":\(searchCount)},\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"tu1\",\"content\":\"results\"}]}}"
    }

    // MARK: - parseMetadata

    func testFeeAppliedForSearchCount() async throws {
        let parser = SessionParser()
        let url = try writeTempFile([assistantRecord(), searchResultRecord(searchCount: 2)])
        defer { try? FileManager.default.removeItem(at: url) }

        let s = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: table)
        XCTAssertEqual(s.estimatedCost, expectedTokenCost + 2 * fee, accuracy: 1e-9,
                       "cost should be token cost plus $0.01 per web search")
    }

    func testNoFeeWhenNoSearchRecord() async throws {
        let parser = SessionParser()
        let url = try writeTempFile([assistantRecord()])
        defer { try? FileManager.default.removeItem(at: url) }

        let s = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: table)
        XCTAssertEqual(s.estimatedCost, expectedTokenCost, accuracy: 1e-9)
    }

    func testNoFeeWhenSearchCountZero() async throws {
        let parser = SessionParser()
        let url = try writeTempFile([assistantRecord(), searchResultRecord(searchCount: 0)])
        defer { try? FileManager.default.removeItem(at: url) }

        let s = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: table)
        XCTAssertEqual(s.estimatedCost, expectedTokenCost, accuracy: 1e-9)
    }

    func testFeeBilledOncePerRecordUUID() async throws {
        let parser = SessionParser()
        // Same tool-result record uuid twice (streaming/replay): billed once.
        let dup = searchResultRecord(searchCount: 2, uuid: "dup-uuid")
        let url = try writeTempFile([assistantRecord(), dup, dup])
        defer { try? FileManager.default.removeItem(at: url) }

        let s = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: table)
        XCTAssertEqual(s.estimatedCost, expectedTokenCost + 2 * fee, accuracy: 1e-9,
                       "a duplicated tool-result uuid must bill the search once")
    }

    func testDistinctSearchRecordsEachBill() async throws {
        let parser = SessionParser()
        let url = try writeTempFile([
            assistantRecord(),
            searchResultRecord(searchCount: 1, uuid: "u-a"),
            searchResultRecord(searchCount: 3, uuid: "u-b"),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let s = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: table)
        XCTAssertEqual(s.estimatedCost, expectedTokenCost + 4 * fee, accuracy: 1e-9)
    }

    // MARK: - Fast-mode independence

    func testFeeNotScaledByFastMode() async throws {
        let parser = SessionParser()
        // Fast mode doubles the token cost but the flat per-search fee is unchanged.
        let url = try writeTempFile([assistantRecord(speed: "fast"), searchResultRecord(searchCount: 2)])
        defer { try? FileManager.default.removeItem(at: url) }

        let s = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: table)
        XCTAssertEqual(s.estimatedCost, expectedTokenCost * 2 + 2 * fee, accuracy: 1e-9,
                       "fast mode doubles tokens only; the search fee stays flat")
    }

    // MARK: - Reconciliation

    func testDailyContributionsIncludeFee() async throws {
        let parser = SessionParser()
        let url = try writeTempFile([assistantRecord(), searchResultRecord(searchCount: 2)])
        defer { try? FileManager.default.removeItem(at: url) }

        let s = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: table)
        let daySum = s.dailyContributions.reduce(0.0) { $0 + $1.estimatedCost }
        XCTAssertEqual(daySum, s.estimatedCost, accuracy: 1e-9,
                       "the fee must keep sum(dailyContributions) == estimatedCost")
    }

    // MARK: - Cowork parity

    func testCoworkStatsBillsSameFeeAsParseMetadata() async throws {
        let lines = [assistantRecord(), searchResultRecord(searchCount: 3)]

        let parser = SessionParser()
        let url = try writeTempFile(lines)
        defer { try? FileManager.default.removeItem(at: url) }
        let parsed = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: table)

        let decoder = JSONDecoder()
        decoder.userInfo[.decodeMode] = DecodeMode.lite
        let records = try lines.map { try decoder.decode(ParsedRecordRaw.self, from: Data($0.utf8)) }
        let totals = CoworkStats.totals(records: records, pricingTable: table)

        XCTAssertEqual(totals.cost, expectedTokenCost + 3 * fee, accuracy: 1e-9)
        XCTAssertEqual(totals.cost, parsed.estimatedCost, accuracy: 1e-9,
                       "Cowork rail/Analytics and parseMetadata must bill web search identically")
    }
}

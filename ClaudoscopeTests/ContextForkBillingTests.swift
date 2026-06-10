import XCTest
@testable import Claudoscope

/// Context-forking subagent transcripts — `agent-acompact-*` (auto-compact) and
/// `agent-aside_question-*` — replay the parent session's history verbatim (same
/// msg.ids, same usage) before issuing their one genuinely new API call. The
/// sidechain bypass plus per-file dedup billed every replayed copy again
/// (~$31 of phantom spend on the author's machine). The parser now drops records
/// whose msg.id appears in the parent transcript from the totals, while leaving
/// them in the transcript for rendering. Ordinary `agent-<hash>` files don't
/// replay, so the prefix gate is deliberately narrow.
final class ContextForkBillingTests: XCTestCase {

    // MARK: - Fixtures

    /// Assistant record with usage. `sidechain: true` marks subagent-file copies.
    private func assistantRecord(uuid: String, msgId: String, input: Int = 100, output: Int = 200, sidechain: Bool = false) -> String {
        let sc = sidechain ? ",\"isSidechain\":true" : ""
        return """
        {"type":"assistant","uuid":"\(uuid)","sessionId":"parent-uuid"\(sc),"timestamp":"2026-04-26T10:00:00.000Z","message":{"role":"assistant","id":"\(msgId)","model":"claude-opus-4-5-20250120","stop_reason":"end_turn","usage":{"input_tokens":\(input),"output_tokens":\(output)}}}
        """
    }

    /// Builds <base>/parent-uuid/subagents/<subFileName> and, when parentLines is
    /// non-nil, the parent transcript at <base>/parent-uuid.jsonl. Returns the
    /// subagent file URL (its <base> is three parents up, for cleanup).
    private func writeFixture(parentLines: [String]?, subFileName: String, subLines: [String]) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-ctxfork-\(UUID().uuidString)")
        let subDir = base.appendingPathComponent("parent-uuid").appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        if let parentLines {
            let parentURL = base.appendingPathComponent("parent-uuid.jsonl")
            try parentLines.joined(separator: "\n").write(to: parentURL, atomically: true, encoding: .utf8)
        }
        let subURL = subDir.appendingPathComponent(subFileName)
        try subLines.joined(separator: "\n").write(to: subURL, atomically: true, encoding: .utf8)
        return subURL
    }

    private func cleanup(_ subURL: URL) {
        let base = subURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try? FileManager.default.removeItem(at: base)
    }

    /// The production parent-path spelling, so the cache test pins mtimes on the
    /// exact file the parser will read.
    private func parentURL(for subURL: URL) -> URL {
        subURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathExtension("jsonl")
    }

    private func replayedSubLines() -> [String] {
        [
            assistantRecord(uuid: "s1", msgId: "msg_A", sidechain: true),
            assistantRecord(uuid: "s2", msgId: "msg_B", sidechain: true),
            assistantRecord(uuid: "s3", msgId: "msg_C", input: 50, output: 75, sidechain: true),
        ]
    }

    private func parentLinesAB() -> [String] {
        [
            assistantRecord(uuid: "p1", msgId: "msg_A"),
            assistantRecord(uuid: "p2", msgId: "msg_B"),
        ]
    }

    // MARK: - acompact / aside exclude parent-replayed records

    func testAcompactExcludesParentReplayedRecords() async throws {
        let parser = SessionParser()
        let pricing = PricingTables.anthropic

        let url = try writeFixture(parentLines: parentLinesAB(),
                                   subFileName: "agent-acompact-abc.jsonl",
                                   subLines: replayedSubLines())
        defer { cleanup(url) }

        let summary = try await parser.parseMetadata(url: url, sessionId: "sub-session", pricingTable: pricing)

        XCTAssertEqual(summary.totalInputTokens, 50, "only the new call C should bill; A,B are parent replays")
        XCTAssertEqual(summary.totalOutputTokens, 75)
    }

    func testAsideQuestionExcludesParentReplayedRecords() async throws {
        let parser = SessionParser()
        let pricing = PricingTables.anthropic

        let url = try writeFixture(parentLines: parentLinesAB(),
                                   subFileName: "agent-aside_question-xyz.jsonl",
                                   subLines: replayedSubLines())
        defer { cleanup(url) }

        let summary = try await parser.parseMetadata(url: url, sessionId: "sub-session", pricingTable: pricing)

        XCTAssertEqual(summary.totalInputTokens, 50)
        XCTAssertEqual(summary.totalOutputTokens, 75)
    }

    // MARK: - plain agent files are NOT excluded

    func testPlainAgentFileWithOverlapIsNotExcluded() async throws {
        let parser = SessionParser()
        let pricing = PricingTables.anthropic

        // Same overlapping ids, but a regular agent file: the narrow prefix gate
        // doesn't fire, so nothing is excluded and all three records bill.
        let url = try writeFixture(parentLines: parentLinesAB(),
                                   subFileName: "agent-deadbeef.jsonl",
                                   subLines: replayedSubLines())
        defer { cleanup(url) }

        let summary = try await parser.parseMetadata(url: url, sessionId: "sub-session", pricingTable: pricing)

        XCTAssertEqual(summary.totalInputTokens, 250, "plain agent file: A+B+C all bill (100+100+50)")
        XCTAssertEqual(summary.totalOutputTokens, 475)
    }

    // MARK: - missing parent bills everything

    func testMissingParentBillsEverything() async throws {
        let parser = SessionParser()
        let pricing = PricingTables.anthropic

        // acompact file but no parent transcript on disk: can't know what was
        // replayed, so fall back to billing everything (and don't cache).
        let url = try writeFixture(parentLines: nil,
                                   subFileName: "agent-acompact-abc.jsonl",
                                   subLines: replayedSubLines())
        defer { cleanup(url) }

        let summary = try await parser.parseMetadata(url: url, sessionId: "sub-session", pricingTable: pricing)

        XCTAssertEqual(summary.totalInputTokens, 250, "no parent on disk: bill everything")
        XCTAssertEqual(summary.totalOutputTokens, 475)
    }

    // MARK: - parse() excludes from totals but keeps transcript records

    func testParseExcludesFromTotalsButKeepsRecords() async throws {
        let parser = SessionParser()

        let url = try writeFixture(parentLines: parentLinesAB(),
                                   subFileName: "agent-acompact-abc.jsonl",
                                   subLines: replayedSubLines())
        defer { cleanup(url) }

        let parsed = try await parser.parse(url: url, sessionId: "sub-session")

        XCTAssertEqual(parsed.metadata.totalInputTokens, 50, "totals exclude the parent replays")
        XCTAssertEqual(parsed.records.count, 3, "all records still retained for transcript rendering")
    }

    // MARK: - cache refresh on parent mtime change

    func testParentMsgIdCacheRefreshesOnMtimeChange() async throws {
        let parser = SessionParser()
        let pricing = PricingTables.anthropic

        // Parent v1 knows only A,B -> C bills.
        let url = try writeFixture(parentLines: parentLinesAB(),
                                   subFileName: "agent-acompact-abc.jsonl",
                                   subLines: replayedSubLines())
        defer { cleanup(url) }
        let parent = parentURL(for: url)
        // Pin mtimes explicitly so the test never trips on mtime granularity.
        let d1 = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: d1], ofItemAtPath: parent.path)

        let first = try await parser.parseMetadata(url: url, sessionId: "sub-session", pricingTable: pricing)
        XCTAssertEqual(first.totalInputTokens, 50, "v1 parent has A,B; C bills")

        // Parent v2 now also contains C; with a fresh mtime the cache must refresh.
        try [
            assistantRecord(uuid: "p1", msgId: "msg_A"),
            assistantRecord(uuid: "p2", msgId: "msg_B"),
            assistantRecord(uuid: "p3", msgId: "msg_C", input: 50, output: 75),
        ].joined(separator: "\n").write(to: parent, atomically: true, encoding: .utf8)
        let d2 = Date(timeIntervalSince1970: 1_700_000_100)
        try FileManager.default.setAttributes([.modificationDate: d2], ofItemAtPath: parent.path)

        let second = try await parser.parseMetadata(url: url, sessionId: "sub-session", pricingTable: pricing)
        XCTAssertEqual(second.totalInputTokens, 0, "v2 parent also has C; cache refreshed, nothing bills")
    }
}

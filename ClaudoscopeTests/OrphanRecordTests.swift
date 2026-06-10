import XCTest
@testable import Claudoscope

/// Regression: streaming intermediate records normally lack `stop_reason` — the
/// final record carries cumulative usage, and the parser used to drop every
/// non-stop_reason record on that assumption. But aborted streams (Ctrl+C,
/// network drops, truncated transcripts) leave behind orphan msg.ids whose
/// stream never produced a stop_reason record. Anthropic still bills those
/// calls, so the parser now counts one record per orphan msg.id — the
/// occurrence carrying the LARGEST cumulative usage (aborted streams persist
/// growing intermediates, and the last/largest is what Anthropic billed), with
/// msg.id dedup keeping it to one. Improvement contributed by Igor during v0.6.2
/// verification; max-usage selection added during the 2026-06 cost pass.
final class OrphanRecordTests: XCTestCase {

    private func writeTempFile(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-orphan-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Helper: assistant record with optional stop_reason and configurable token amounts.
    private func record(uuid: String, msgId: String, stopReason: String?, input: Int = 100, output: Int = 200, timestamp: String = "2026-04-26T10:00:00.000Z") -> String {
        let stopReasonField = stopReason.map { "\"stop_reason\":\"\($0)\"," } ?? "\"stop_reason\":null,"
        return """
        {"type":"assistant","uuid":"\(uuid)","sessionId":"sess-1","timestamp":"\(timestamp)","message":{"role":"assistant","id":"\(msgId)","model":"claude-opus-4-5-20250120",\(stopReasonField)"usage":{"input_tokens":\(input),"output_tokens":\(output)}}}
        """
    }

    /// Local-day key for an ISO timestamp, mirroring SessionParser's per-day
    /// cost attribution so the tie-break assertion is timezone-independent.
    private func localDayKey(_ iso: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: ISO8601.parse(iso)!)
    }

    // MARK: - Orphan billed once

    func testOrphanMessageIdIsBilledOnce() async throws {
        let parser = SessionParser()
        let pricing = PricingTables.anthropic

        // Two records sharing the same msg.id, neither has stop_reason.
        // Without the orphan fix: dropped (zero tokens).
        // With the orphan fix: one record billed (msg.id dedup keeps it to one).
        let url = try writeTempFile([
            record(uuid: "u1", msgId: "msg_orphan", stopReason: nil),
            record(uuid: "u2", msgId: "msg_orphan", stopReason: nil),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: pricing)

        XCTAssertEqual(summary.totalInputTokens, 100, "orphan msg.id should be billed once")
        XCTAssertEqual(summary.totalOutputTokens, 200)
    }

    // MARK: - Normal stream: only stop_reason record counted

    func testNormalStreamWithStopReasonOnlyCountsFinalRecord() async throws {
        let parser = SessionParser()
        let pricing = PricingTables.anthropic

        // Three records sharing msg.id: two intermediates with stop_reason=null,
        // one final with stop_reason set. Only the final should be billed.
        // The orphan fix MUST NOT change this behavior — intermediates whose
        // msg.id has a stop_reason record elsewhere in the file are still dropped.
        let url = try writeTempFile([
            record(uuid: "u1", msgId: "msg_normal", stopReason: nil, input: 10, output: 20),
            record(uuid: "u2", msgId: "msg_normal", stopReason: nil, input: 50, output: 100),
            record(uuid: "u3", msgId: "msg_normal", stopReason: "end_turn", input: 100, output: 200),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: pricing)

        XCTAssertEqual(summary.totalInputTokens, 100, "only the final stop_reason record should bill")
        XCTAssertEqual(summary.totalOutputTokens, 200)
    }

    // MARK: - Mixed: orphan + normal in same file

    func testMixedOrphanAndNormalRecordsInSameFile() async throws {
        let parser = SessionParser()
        let pricing = PricingTables.anthropic

        // msg_normal: stream completed (intermediate + final). Bill final only.
        // msg_orphan: stream aborted (intermediate only, no final). Bill the orphan.
        // Expected: 100 (normal final) + 50 (orphan) = 150 input.
        let url = try writeTempFile([
            record(uuid: "u1", msgId: "msg_normal", stopReason: nil, input: 10, output: 20),
            record(uuid: "u2", msgId: "msg_normal", stopReason: "end_turn", input: 100, output: 200),
            record(uuid: "u3", msgId: "msg_orphan", stopReason: nil, input: 50, output: 75),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: pricing)

        XCTAssertEqual(summary.totalInputTokens, 150, "100 from normal final + 50 from orphan")
        XCTAssertEqual(summary.totalOutputTokens, 275, "200 from normal final + 75 from orphan")
    }

    // MARK: - parse() also includes orphans

    func testFullParseIncludesOrphans() async throws {
        let parser = SessionParser()

        let url = try writeTempFile([
            record(uuid: "u1", msgId: "msg_orphan_a", stopReason: nil, input: 100, output: 200),
            record(uuid: "u2", msgId: "msg_orphan_b", stopReason: nil, input: 50, output: 75),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let parsed = try await parser.parse(url: url, sessionId: "sess-1")

        XCTAssertEqual(parsed.metadata.totalInputTokens, 150, "two distinct orphans, each billed once")
        XCTAssertEqual(parsed.metadata.totalOutputTokens, 275)
    }

    // MARK: - Record without msg.id — counted as orphan

    func testRecordWithoutMessageIdCountsAsOrphan() async throws {
        let parser = SessionParser()
        let pricing = PricingTables.anthropic

        // Record has no message.id at all. There's no way to tell if it's
        // related to another record, so the orphan rule treats it as billable.
        // (Matches the bash diagnostic's `$has_stop[.message.id // ""] // false`
        // behavior — empty msg.id is never in the has_stop set.)
        let noIdRecord = """
        {"type":"assistant","uuid":"u1","sessionId":"sess-1","timestamp":"2026-04-26T10:00:00.000Z","message":{"role":"assistant","model":"claude-opus-4-5","usage":{"input_tokens":50,"output_tokens":75}}}
        """
        let url = try writeTempFile([noIdRecord])
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: pricing)

        XCTAssertEqual(summary.totalInputTokens, 50)
        XCTAssertEqual(summary.totalOutputTokens, 75)
    }

    // MARK: - Growing-usage orphan bills the max record

    func testGrowingUsageOrphanBillsMaxViaParseMetadata() async throws {
        let parser = SessionParser()
        let pricing = PricingTables.anthropic

        // Aborted stream: three intermediates, one msg.id, no stop_reason, usage
        // grows (output 10 -> 50 -> 120). The largest cumulative record is what
        // Anthropic actually billed, so totals must reflect output 120, not 10.
        let url = try writeTempFile([
            record(uuid: "u1", msgId: "msg_grow", stopReason: nil, input: 100, output: 10),
            record(uuid: "u2", msgId: "msg_grow", stopReason: nil, input: 100, output: 50),
            record(uuid: "u3", msgId: "msg_grow", stopReason: nil, input: 100, output: 120),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: pricing)

        XCTAssertEqual(summary.totalInputTokens, 100, "orphan billed once at the max-usage record")
        XCTAssertEqual(summary.totalOutputTokens, 120, "max cumulative output, not the first intermediate")
    }

    func testGrowingUsageOrphanBillsMaxViaParse() async throws {
        let parser = SessionParser()

        let url = try writeTempFile([
            record(uuid: "u1", msgId: "msg_grow", stopReason: nil, input: 100, output: 10),
            record(uuid: "u2", msgId: "msg_grow", stopReason: nil, input: 100, output: 50),
            record(uuid: "u3", msgId: "msg_grow", stopReason: nil, input: 100, output: 120),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let parsed = try await parser.parse(url: url, sessionId: "sess-1")

        XCTAssertEqual(parsed.metadata.totalInputTokens, 100)
        XCTAssertEqual(parsed.metadata.totalOutputTokens, 120, "parse() must agree with parseMetadata on max-usage billing")
    }

    // MARK: - Equal-usage tie bills the LAST occurrence

    func testEqualUsageOrphanTiebreakBillsLastOccurrence() async throws {
        let parser = SessionParser()
        let pricing = PricingTables.anthropic

        // Two equal-usage orphan copies on different local days. Totals are the
        // same whichever is chosen, so the only observable signal is the day the
        // cost lands on: ties resolve to the LAST occurrence (the stream's final
        // write), so the later day must carry the contribution.
        let earlier = "2026-04-26T10:00:00.000Z"
        let later = "2026-04-27T10:00:00.000Z"
        let url = try writeTempFile([
            record(uuid: "u1", msgId: "msg_tie", stopReason: nil, input: 100, output: 200, timestamp: earlier),
            record(uuid: "u2", msgId: "msg_tie", stopReason: nil, input: 100, output: 200, timestamp: later),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: pricing)

        XCTAssertEqual(summary.totalOutputTokens, 200, "billed exactly once")
        XCTAssertEqual(summary.dailyContributions.count, 1, "only the chosen occurrence contributes a day")
        XCTAssertEqual(summary.dailyContributions.first?.date, localDayKey(later),
                       "tie resolves to the LAST occurrence's day")
    }
}

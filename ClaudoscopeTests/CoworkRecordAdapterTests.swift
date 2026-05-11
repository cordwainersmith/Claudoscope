import XCTest
@testable import Claudoscope

final class CoworkRecordAdapterTests: XCTestCase {

    // MARK: - Adapter unit behaviour

    func testRenamesAuditTimestampToTimestamp() throws {
        let raw = #"{"type":"user","_audit_timestamp":"2026-05-08T12:00:00.000Z","uuid":"u1"}"#
        let adapted = try XCTUnwrap(CoworkRecordAdapter.adaptLine(raw))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(adapted.utf8)) as? [String: Any])
        XCTAssertEqual(json["timestamp"] as? String, "2026-05-08T12:00:00.000Z")
        XCTAssertNil(json["_audit_timestamp"])
    }

    func testTimestampWinsOverAuditTimestampWhenBothPresent() throws {
        let raw = #"{"type":"user","timestamp":"keep","_audit_timestamp":"drop","uuid":"u1"}"#
        let adapted = try XCTUnwrap(CoworkRecordAdapter.adaptLine(raw))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(adapted.utf8)) as? [String: Any])
        XCTAssertEqual(json["timestamp"] as? String, "keep")
        XCTAssertNil(json["_audit_timestamp"])
    }

    func testStripsInnerSessionId() throws {
        let raw = #"{"type":"user","session_id":"inner-id","uuid":"u1","_audit_timestamp":"t"}"#
        let adapted = try XCTUnwrap(CoworkRecordAdapter.adaptLine(raw))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(adapted.utf8)) as? [String: Any])
        XCTAssertNil(json["session_id"])
        XCTAssertNil(json["sessionId"])
    }

    func testReturnsNilForBlankLines() {
        XCTAssertNil(CoworkRecordAdapter.adaptLine(""))
        XCTAssertNil(CoworkRecordAdapter.adaptLine("   "))
        XCTAssertNil(CoworkRecordAdapter.adaptLine("\n"))
    }

    func testReturnsNilForMalformedJson() {
        XCTAssertNil(CoworkRecordAdapter.adaptLine("{not json"))
        XCTAssertNil(CoworkRecordAdapter.adaptLine("[1, 2, 3]"))
    }

    func testPassesThroughUploadedFilesBlocks() throws {
        let raw = #"{"type":"user","_audit_timestamp":"t","message":{"role":"user","content":"<uploaded_files>\n<file><file_path>/tmp/x.md</file_path></file>\n</uploaded_files>\n\nplease summarise"}}"#
        let adapted = try XCTUnwrap(CoworkRecordAdapter.adaptLine(raw))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(adapted.utf8)) as? [String: Any])
        let message = try XCTUnwrap(json["message"] as? [String: Any])
        let content = try XCTUnwrap(message["content"] as? String)
        XCTAssertTrue(content.contains("<uploaded_files>"))
        XCTAssertTrue(content.contains("/tmp/x.md"))
    }

    // MARK: - Parity with SessionParser

    /// Cross-validation: the same usage block decoded via the Cowork path
    /// (raw → adapter → SessionParser) must produce the same token totals
    /// as feeding the equivalent Claude-Code-shaped JSONL into SessionParser
    /// directly. This guards against any future adapter drift silently
    /// changing billable numbers.
    func testParityWithSessionParser_sameUsageNumbersAsClaudeCodeFile() async throws {
        let parser = SessionParser()

        let coworkLines = [
            #"{"type":"user","_audit_timestamp":"2026-05-08T10:00:00.000Z","uuid":"u-1","session_id":"inner-cowork","message":{"role":"user","content":"hello"}}"#,
            #"{"type":"assistant","_audit_timestamp":"2026-05-08T10:00:01.000Z","uuid":"a-1","session_id":"inner-cowork","message":{"id":"msg_1","role":"assistant","model":"claude-sonnet-4-6","stop_reason":"end_turn","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":20,"cache_creation_input_tokens":10}}}"#
        ]
        let claudeCodeLines = [
            #"{"type":"user","timestamp":"2026-05-08T10:00:00.000Z","uuid":"u-1","message":{"role":"user","content":"hello"}}"#,
            #"{"type":"assistant","timestamp":"2026-05-08T10:00:01.000Z","uuid":"a-1","message":{"id":"msg_1","role":"assistant","model":"claude-sonnet-4-6","stop_reason":"end_turn","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":20,"cache_creation_input_tokens":10}}}"#
        ]

        let coworkURL = try writeTemp(lines: coworkLines.compactMap(CoworkRecordAdapter.adaptLine), name: "cowork-parity.jsonl")
        let claudeURL = try writeTemp(lines: claudeCodeLines, name: "claude-parity.jsonl")
        defer {
            try? FileManager.default.removeItem(at: coworkURL)
            try? FileManager.default.removeItem(at: claudeURL)
        }

        let coworkSession = try await parser.parse(url: coworkURL, sessionId: "outer-cowork")
        let claudeSession = try await parser.parse(url: claudeURL, sessionId: "outer-cowork")

        XCTAssertEqual(coworkSession.metadata.totalInputTokens, claudeSession.metadata.totalInputTokens)
        XCTAssertEqual(coworkSession.metadata.totalOutputTokens, claudeSession.metadata.totalOutputTokens)
        XCTAssertEqual(coworkSession.metadata.totalCacheReadTokens, claudeSession.metadata.totalCacheReadTokens)
        XCTAssertEqual(coworkSession.metadata.totalCacheCreationTokens, claudeSession.metadata.totalCacheCreationTokens)
        XCTAssertEqual(coworkSession.metadata.assistantMessageCount, claudeSession.metadata.assistantMessageCount)
        XCTAssertGreaterThan(coworkSession.metadata.totalOutputTokens, 0, "sanity: parity test produced zero tokens")
    }

    /// Regression: Cowork's audit.jsonl frequently writes assistant records
    /// with `usage` and `message.id` but **no** `stop_reason`. Token totals
    /// must still be non-zero — SessionParser's "orphan stream" rule treats
    /// any msg.id that never has stop_reason as billable on its first record.
    /// Without this, the Cowork stats card displays zeros (the bug shipped in
    /// the first iteration). The test asserts the sum survives via the parser.
    func testRecordsWithoutStopReason_areStillBilled() async throws {
        let parser = SessionParser()
        let lines = [
            #"{"type":"user","_audit_timestamp":"t1","uuid":"u-1","message":{"role":"user","content":"hi"}}"#,
            #"{"type":"assistant","_audit_timestamp":"t2","uuid":"a-1","message":{"id":"msg_a","role":"assistant","model":"claude-sonnet-4-6","content":[{"type":"text","text":"yo"}],"usage":{"input_tokens":42,"output_tokens":7}}}"#
        ]
        let url = try writeTemp(lines: lines.compactMap(CoworkRecordAdapter.adaptLine), name: "no-stopreason.jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let session = try await parser.parse(url: url, sessionId: "outer-cowork")
        XCTAssertEqual(session.metadata.totalInputTokens, 42, "orphan record without stop_reason was dropped — billing logic broken")
        XCTAssertEqual(session.metadata.totalOutputTokens, 7)
    }

    /// Regression: SessionParser's parent-skip branch drops every record whose
    /// top-level `sessionId` differs from the file's session ID. If the adapter
    /// failed to strip Cowork's inner `session_id`, every billable assistant
    /// turn would be silently dropped. This test asserts billable tokens
    /// survive when the inner ID would have shadowed.
    func testInnerSessionIdShadowing_doesNotDropBillableRecords() async throws {
        let parser = SessionParser()

        // Inner session_id deliberately differs from the outer sessionId we
        // pass to the parser. Without the adapter strip, parent-skip kicks in.
        let lines = [
            #"{"type":"user","_audit_timestamp":"t1","uuid":"u-1","session_id":"would-be-parent","message":{"role":"user","content":"hi"}}"#,
            #"{"type":"assistant","_audit_timestamp":"t2","uuid":"a-1","session_id":"would-be-parent","message":{"id":"msg_a","role":"assistant","model":"claude-sonnet-4-6","stop_reason":"end_turn","content":[{"type":"text","text":"yo"}],"usage":{"input_tokens":1000,"output_tokens":500}}}"#
        ]
        let url = try writeTemp(lines: lines.compactMap(CoworkRecordAdapter.adaptLine), name: "shadow.jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let session = try await parser.parse(url: url, sessionId: "outer-cowork")
        XCTAssertEqual(session.metadata.totalInputTokens, 1000, "billable tokens were dropped — adapter likely failed to strip session_id")
        XCTAssertEqual(session.metadata.totalOutputTokens, 500)
    }

    // MARK: - Helpers

    private func writeTemp(lines: [String], name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cowork-adapter-tests-\(UUID().uuidString)-\(name)")
        let body = lines.joined(separator: "\n") + "\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

import XCTest
@testable import Claudoscope

final class DecodeModeTests: XCTestCase {

    // MARK: - Helpers

    private func liteDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.userInfo[.decodeMode] = DecodeMode.lite
        return d
    }

    private func fullDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.userInfo[.decodeMode] = DecodeMode.full
        return d
    }

    private func decodeLite(_ json: String) throws -> ParsedRecordRaw {
        try liteDecoder().decode(ParsedRecordRaw.self, from: Data(json.utf8))
    }

    private func decodeFull(_ json: String) throws -> ParsedRecordRaw {
        try fullDecoder().decode(ParsedRecordRaw.self, from: Data(json.utf8))
    }

    // MARK: - Regression guards

    // Round 2 regression: thinking char count was hardcoded to 0, breaking effort classification.
    func testThinkingBlockPreservedInLite() throws {
        let json = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hello world"}]}}
        """
        let raw = try decodeLite(json)
        guard case .blocks(let blocks) = raw.message?.content else {
            return XCTFail("expected blocks content")
        }
        let thinkingChars = blocks
            .filter { $0.type == "thinking" }
            .compactMap { $0.thinking?.count }
            .reduce(0, +)
        XCTAssertEqual(thinkingChars, "hello world".count)
    }

    // Round 2 regression: error text in result.message.content (string form) was lost.
    func testResultErrorTextStringFormPreservedInLite() throws {
        let json = """
        {"type":"result","message":{"role":"assistant","stop_reason":"error","content":"rate limit exceeded"}}
        """
        let raw = try decodeLite(json)
        XCTAssertEqual(raw.message?.content?.textContent, "rate limit exceeded")
    }

    // Round 2 regression: error text in result.message.content (blocks form) was lost.
    func testResultErrorTextBlocksFormPreservedInLite() throws {
        let json = """
        {"type":"result","message":{"role":"assistant","stop_reason":"error","content":[{"type":"text","text":"auth failed"},{"type":"text","text":"token invalid"}]}}
        """
        let raw = try decodeLite(json)
        XCTAssertEqual(raw.message?.content?.textContent, "auth failed\ntoken invalid")
    }

    // Round 3 regression: top-level result.content (separate from message.content) was missed.
    func testTopLevelResultContentPreservedInLite() throws {
        let json = """
        {"type":"result","content":"server returned 500"}
        """
        let raw = try decodeLite(json)
        XCTAssertEqual(raw.content, "server returned 500")
    }

    // Round 3 rebase regression: compactMetadata.preTokens reverted to nil.
    func testCompactMetadataPreTokensPreservedInLite() throws {
        let json = """
        {"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"auto","preTokens":12345}}
        """
        let raw = try decodeLite(json)
        XCTAssertEqual(raw.compactMetadata?.preTokens, 12345)
    }

    // Perf-load-bearing: the .input dict on tool_use blocks is the dominant decode cost.
    // Lite mode must never visit it. Fixture includes a real populated input so a future
    // contributor accidentally adding `decodeIfPresent(.input)` to the lite branch would
    // cause this test to fail (block.input would become non-nil).
    func testHeavyInputSkippedInLite() throws {
        let json = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"ls -la"}}]}}
        """

        let liteRaw = try decodeLite(json)
        guard case .blocks(let liteBlocks) = liteRaw.message?.content else {
            return XCTFail("expected blocks content")
        }
        XCTAssertEqual(liteBlocks.first?.type, "tool_use")
        XCTAssertEqual(liteBlocks.first?.name, "Bash")
        XCTAssertNil(liteBlocks.first?.input, "lite mode must not decode .input")

        let fullRaw = try decodeFull(json)
        guard case .blocks(let fullBlocks) = fullRaw.message?.content else {
            return XCTFail("expected blocks content")
        }
        XCTAssertNotNil(fullBlocks.first?.input, "full mode must decode .input (sanity check)")
    }

    // Continuation detection in parseMetadata reads top-level sessionId to identify
    // parent-session records and skip them. Dropping it from lite would silently break
    // continuation handling.
    func testContinuationSessionIdPreservedInLite() throws {
        let json = """
        {"type":"user","sessionId":"parent-session-uuid","message":{"role":"user","content":"hello"}}
        """
        let raw = try decodeLite(json)
        XCTAssertEqual(raw.sessionId, "parent-session-uuid")
    }

    // Hook runtime aggregation needs the slim attachment fields in lite mode,
    // but stdout/stderr/content can be large (embedded hookSpecificOutput JSON)
    // and are full-only.
    func testHookAttachmentSlimInLite() throws {
        let json = """
        {"type":"attachment","attachment":{"type":"hook_success","hookName":"PreToolUse:Bash","hookEvent":"PreToolUse","command":"/x/guard.sh","durationMs":120,"exitCode":0,"stdout":"big payload","stderr":"","content":"ctx"}}
        """
        let raw = try decodeLite(json)
        XCTAssertEqual(raw.type, .attachment)
        let att = try XCTUnwrap(raw.attachment)
        XCTAssertEqual(att.hookName, "PreToolUse:Bash")
        XCTAssertEqual(att.command, "/x/guard.sh")
        XCTAssertEqual(att.durationMs, 120)
        XCTAssertEqual(att.exitCode, 0)
        XCTAssertNil(att.stdout, "lite mode must not decode attachment stdout")
        XCTAssertNil(att.stderr)
        XCTAssertNil(att.content)

        let full = try XCTUnwrap(try decodeFull(json).attachment)
        XCTAssertEqual(full.stdout, "big payload")
        XCTAssertEqual(full.content, "ctx")
    }

    func testStopHookSummaryFieldsPreservedInLite() throws {
        let json = """
        {"type":"system","subtype":"stop_hook_summary","hookCount":2,"hookInfos":[{"command":"notify.sh","durationMs":50},{"command":"http://localhost/hook"}],"hookErrors":["ECONNREFUSED"],"preventedContinuation":true}
        """
        let raw = try decodeLite(json)
        XCTAssertEqual(raw.hookCount, 2)
        XCTAssertEqual(raw.hookInfos?.count, 2)
        XCTAssertEqual(raw.hookInfos?[0].command, "notify.sh")
        XCTAssertEqual(raw.hookInfos?[0].durationMs, 50)
        XCTAssertNil(raw.hookInfos?[1].durationMs)
        XCTAssertEqual(raw.hookErrors, ["ECONNREFUSED"])
        XCTAssertEqual(raw.preventedContinuation, true)
    }
}

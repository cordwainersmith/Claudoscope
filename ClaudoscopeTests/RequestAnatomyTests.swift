import XCTest
@testable import Claudoscope

/// Request anatomy rebuilt from `api-request`, `api-request-shape` and
/// `api-request-blob` lines (Claude Code 2.1.300+).
final class RequestAnatomyTests: XCTestCase {

    private func write(_ lines: [String], subagent: Bool = false) throws -> URL {
        var dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-anatomy-\(UUID().uuidString)")
        if subagent { dir = dir.appendingPathComponent("parent").appendingPathComponent("subagents") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("s1.jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 100-byte system text, a built-in tool, two MCP tools on one server and
    /// one deferred tool.
    private let shape = #"{"type":"api-request-shape","sessionId":"s1","shapeHash":"h1","shape":{"system":[{"type":"text","text":"\#(String(repeating: "s", count: 100))"}],"tools":[{"name":"Bash","description":"run"},{"name":"mcp__jira__search","description":"find"},{"name":"mcp__jira__get","description":"get"},{"name":"WebFetch","description":"fetch","defer_loading":true}]}}"#

    private func blob(_ hash: String, role: String, text: String) -> String {
        #"{"type":"api-request-blob","sessionId":"s1","hash":"\#(hash)","message":{"role":"\#(role)","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    private func request(_ id: String, base: String? = nil, keep: Int = 0, tail: [String], source: String = "repl_main_thread") -> String {
        let baseField = base.map { #","base":"\#($0)""# } ?? ""
        let tailJSON = tail.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"type":"api-request","sessionId":"s1","id":"\#(id)","timestamp":"2026-11-05T10:00:00.000Z","querySource":"\#(source)","shapeHash":"h1","params":{"model":"claude-opus-5-5","output_config":{"effort":"high"}}\#(baseField),"keep":\#(keep),"tail":[\#(tailJSON)]}"#
    }

    private func assistant(ref: String, total: Int) -> String {
        #"{"type":"assistant","uuid":"a-\#(ref)","sessionId":"s1","requestRef":"\#(ref)","message":{"role":"assistant","id":"m-\#(ref)","stop_reason":"end_turn","usage":{"input_tokens":\#(total / 2),"cache_read_input_tokens":\#(total - total / 2),"output_tokens":5}}}"#
    }

    private func build(_ lines: [String], subagent: Bool = false) throws -> RequestAnatomy {
        try RequestAnatomyService.build(url: try write(lines, subagent: subagent), sessionKey: "k", includeAgentRequests: subagent)
    }

    func testCompleteRequestsSplitRealTotalBySize() throws {
        let a = try build([
            shape,
            blob("b1", role: "user", text: "<system-reminder>claude md</system-reminder>"),
            blob("b2", role: "user", text: "hello"),
            request("r1", tail: ["b1", "b2"]),
            assistant(ref: "r1", total: 1000),
            blob("b3", role: "assistant", text: "hi there"),
            blob("b4", role: "user", text: "more"),
            request("r2", base: "r1", keep: 2, tail: ["b3", "b4"]),
            assistant(ref: "r2", total: 1200),
            request("r3", base: "r2", keep: 4, tail: []),
            assistant(ref: "r3", total: 1300),
        ])
        XCTAssertEqual(a.points.count, 3)
        XCTAssertTrue(a.points.allSatisfy(\.isMeasured))
        XCTAssertEqual(a.points[0].totalTokens, 1000, accuracy: 3)
        XCTAssertEqual(a.points[1].totalTokens, 1200, accuracy: 3)
        // r2 rebuilds as r1's 2 messages + 2 new, so its conversation bytes grew.
        XCTAssertGreaterThan(a.points[1].bytes[.conversation] ?? 0, a.points[0].bytes[.conversation] ?? 0)
        XCTAssertEqual(a.points[1].bytes[.conversation], a.points[2].bytes[.conversation])
        XCTAssertGreaterThan(a.points[0].tokens[.reminders] ?? 0, 0)
        XCTAssertEqual(a.points[0].effort, "high")
        XCTAssertEqual(a.latest?.point.id, "r3")
        XCTAssertEqual(a.peak?.point.id, "r3")
    }

    func testMissingBlobLeavesConversationAsRemainder() throws {
        let a = try build([
            shape,
            blob("b1", role: "user", text: "<system-reminder>claude md</system-reminder>"),
            request("r1", tail: ["b1", "not-in-file"]),
            assistant(ref: "r1", total: 5000),
        ])
        let p = try XCTUnwrap(a.points.first)
        XCTAssertTrue(p.isMeasured)
        XCTAssertEqual(p.totalTokens, 5000)
        let fixed = p.totalTokens - (p.tokens[.conversation] ?? 0)
        XCTAssertGreaterThan(p.tokens[.conversation] ?? 0, fixed, "the unknown message dominates")
    }

    func testDeferredToolsExcludedAndMcpGroupedByServer() throws {
        let a = try build([shape, request("r1", tail: []), assistant(ref: "r1", total: 400)])
        let detail = try XCTUnwrap(a.latest)
        XCTAssertEqual(detail.point.deferredToolCount, 1)
        XCTAssertEqual(detail.mcpByServer.map(\.server), ["jira"])
        XCTAssertEqual(detail.mcpByServer.first?.toolCount, 2)
        XCTAssertFalse(detail.topTools.contains { $0.name == "WebFetch" })
        XCTAssertGreaterThan(detail.point.tokens[.mcpTools] ?? 0, detail.point.tokens[.builtinTools] ?? 0)
    }

    func testMissingBaseTreatsHistoryAsUnknown() throws {
        let a = try build([shape, request("r2", base: "gone", keep: 10, tail: []), assistant(ref: "r2", total: 900)])
        let p = try XCTUnwrap(a.points.first)
        XCTAssertEqual(p.totalTokens, 900)
        XCTAssertGreaterThan(p.tokens[.conversation] ?? 0, 0)
    }

    func testUnmatchedRequestIsEstimated() throws {
        let a = try build([shape, blob("b1", role: "user", text: "hi"), request("r1", tail: ["b1"])])
        XCTAssertEqual(a.points.first?.isMeasured, false)
    }

    func testMainTranscriptSkipsSubagentRequests() throws {
        let lines = [shape, request("r1", tail: []), request("r2", tail: [], source: "agent:explore")]
        XCTAssertEqual(try build(lines).points.map(\.id), ["r1"])
        XCTAssertEqual(try build(lines, subagent: true).points.map(\.id), ["r1", "r2"])
    }

    func testNoRequestLogGivesEmptyAnatomy() throws {
        let a = try build([#"{"type":"user","uuid":"u1","sessionId":"s1","message":{"role":"user","content":"hi"}}"#])
        XCTAssertTrue(a.points.isEmpty)
        XCTAssertNil(a.latest)
    }

    func testServiceCachesUntilFileChanges() async throws {
        let url = try write([shape, request("r1", tail: []), assistant(ref: "r1", total: 400)])
        let service = RequestAnatomyService()
        let first = try await service.load(url: url, sessionKey: "k")
        let again = try await service.load(url: url, sessionKey: "k")
        XCTAssertEqual(first, again)
        try ([shape, request("r1", tail: []), assistant(ref: "r1", total: 400), request("r2", base: "r1", keep: 0, tail: [])]
            .joined(separator: "\n")).write(to: url, atomically: true, encoding: .utf8)
        let changed = try await service.load(url: url, sessionKey: "k")
        XCTAssertEqual(changed.points.count, 2)
    }

    func testMcpServerSegment() {
        XCTAssertEqual(RequestAnatomyService.mcpServer(of: "mcp__claude_ai_Gmail__search"), "claude_ai_Gmail")
        XCTAssertEqual(RequestAnatomyService.mcpServer(of: "mcp__solo"), "solo")
        XCTAssertNil(RequestAnatomyService.mcpServer(of: "Bash"))
    }
}

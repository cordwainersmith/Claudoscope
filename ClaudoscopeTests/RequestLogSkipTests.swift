import XCTest
@testable import Claudoscope

/// Claude Code 2.1.300+ writes `api-request`, `api-request-shape` and
/// `api-request-blob` lines into the transcript. They describe what was sent to
/// the API and must not count as messages, move timestamps, or bill.
final class RequestLogSkipTests: XCTestCase {

    private let conversation = [
        #"{"type":"user","uuid":"u1","sessionId":"s1","timestamp":"2026-11-01T10:00:00.000Z","message":{"role":"user","content":"hi"}}"#,
        #"{"type":"assistant","uuid":"a1","sessionId":"s1","timestamp":"2026-11-01T10:00:05.000Z","message":{"role":"assistant","id":"msg_1","model":"claude-sonnet-4-6","stop_reason":"end_turn","content":[{"type":"text","text":"hello"}],"usage":{"input_tokens":1000,"output_tokens":2000}}}"#,
        #"{"type":"user","uuid":"u2","sessionId":"s1","timestamp":"2026-11-01T10:01:00.000Z","message":{"role":"user","content":"again"}}"#,
        #"{"type":"assistant","uuid":"a2","sessionId":"s1","timestamp":"2026-11-01T10:01:05.000Z","message":{"role":"assistant","id":"msg_2","model":"claude-sonnet-4-6","stop_reason":"end_turn","content":[{"type":"text","text":"yes"}],"usage":{"input_tokens":1000,"output_tokens":2000}}}"#,
    ]

    private let requestLog = [
        #"{"type":"api-request-shape","sessionId":"s1","shapeHash":"h1","timestamp":"2026-11-02T09:00:00.000Z","version":"2.1.318","shape":{"system":[{"type":"text","text":"You are Claude Code"}],"tools":[{"name":"Bash","description":"run"}]}}"#,
        #"{"type":"api-request","sessionId":"s1","id":"r1","timestamp":"2026-11-02T09:00:01.000Z","version":"2.1.318","querySource":"repl_main_thread","shapeHash":"h1","params":{"model":"claude-sonnet-4-6","max_tokens":1000},"keep":0,"tail":["b1"],"cacheControl":[],"requestDigest":"d1"}"#,
        #"{"type":"api-request-blob","sessionId":"s1","hash":"b1","message":{"role":"assistant","content":[{"type":"text","text":"copied"}]}}"#,
    ]

    private func write(_ lines: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-reqlog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("s1.jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testRecognizesAllThreeRequestLogTypes() {
        for line in requestLog {
            XCTAssertTrue(SessionParser.isRequestLogLine(line), line)
        }
        for line in conversation {
            XCTAssertFalse(SessionParser.isRequestLogLine(line), line)
        }
    }

    func testLiteSummaryIgnoresRequestLog() async throws {
        let clean = try write(conversation)
        let withLog = try write(conversation + requestLog)
        let parser = SessionParser()
        let a = try await parser.parseMetadata(url: clean, sessionId: "s1", pricingTable: PricingTables.anthropic)
        let b = try await parser.parseMetadata(url: withLog, sessionId: "s1", pricingTable: PricingTables.anthropic)
        XCTAssertEqual(a.messageCount, b.messageCount)
        XCTAssertEqual(a.lastTimestamp, b.lastTimestamp)
        XCTAssertEqual(a.estimatedCost, b.estimatedCost, accuracy: 1e-9)
        XCTAssertEqual(b.lastTimestamp, "2026-11-01T10:01:05.000Z")
    }

    func testFullParseIgnoresRequestLog() async throws {
        let clean = try write(conversation)
        let withLog = try write(conversation + requestLog)
        let parser = SessionParser()
        let a = try await parser.parse(url: clean, sessionId: "s1")
        let b = try await parser.parse(url: withLog, sessionId: "s1")
        XCTAssertEqual(a.records.count, b.records.count)
        XCTAssertEqual(a.metadata.messageCount, b.metadata.messageCount)
        XCTAssertEqual(a.metadata.lastTimestamp, b.metadata.lastTimestamp)
    }
}

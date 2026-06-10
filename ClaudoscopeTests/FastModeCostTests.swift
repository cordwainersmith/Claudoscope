import XCTest
@testable import Claudoscope

/// Tests for Track A: fast-mode cost multiplier (#1) and session-title
/// precedence (#5).
final class FastModeCostTests: XCTestCase {

    private func writeTempFile(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-fastmode-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A billed assistant record (stop_reason present so it is counted once).
    /// `speed` is placed inside the usage block (sibling of service_tier), which
    /// is where Claude Code records the fast-mode signal.
    private func billedRecord(
        msgId: String,
        speed: String? = nil,
        input: Int = 1000,
        output: Int = 2000,
        uuid: String = UUID().uuidString
    ) -> String {
        let speedField = speed.map { "\"speed\":\"\($0)\"," } ?? ""
        return "{\"type\":\"assistant\",\"uuid\":\"\(uuid)\",\"sessionId\":\"sess-1\",\"timestamp\":\"2026-04-26T10:00:00.000Z\",\"message\":{\"role\":\"assistant\",\"id\":\"\(msgId)\",\"stop_reason\":\"end_turn\",\"model\":\"claude-opus-4-5-20250120\",\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\(speedField)\"service_tier\":\"standard\"}}}"
    }

    // MARK: - #1 fast-mode multiplier

    func testFastModeDoublesCost() async throws {
        let parser = SessionParser()
        let pricing = PricingTables.anthropic

        let stdURL = try writeTempFile([billedRecord(msgId: "m1", speed: "standard")])
        let fastURL = try writeTempFile([billedRecord(msgId: "m1", speed: "fast")])
        defer { try? FileManager.default.removeItem(at: stdURL); try? FileManager.default.removeItem(at: fastURL) }

        let std = try await parser.parseMetadata(url: stdURL, sessionId: "sess-1", pricingTable: pricing)
        let fast = try await parser.parseMetadata(url: fastURL, sessionId: "sess-1", pricingTable: pricing)

        XCTAssertGreaterThan(std.estimatedCost, 0)
        XCTAssertEqual(fast.estimatedCost, std.estimatedCost * 2.0, accuracy: 1e-9,
                       "a fast-mode turn should bill at the 2x rate")
    }

    // MARK: - #5 title precedence

    func testTitleFieldWinsOverSlug() async throws {
        let parser = SessionParser()
        let pricing = PricingTables.anthropic
        let rec = "{\"type\":\"assistant\",\"uuid\":\"u1\",\"sessionId\":\"sess-1\",\"slug\":\"slug-name\",\"title\":\"Real Title\",\"timestamp\":\"2026-04-26T10:00:00.000Z\",\"message\":{\"role\":\"assistant\",\"id\":\"m1\",\"stop_reason\":\"end_turn\",\"model\":\"claude-opus-4-5-20250120\",\"usage\":{\"input_tokens\":10,\"output_tokens\":20}}}"
        let url = try writeTempFile([rec])
        defer { try? FileManager.default.removeItem(at: url) }

        let s = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: pricing)
        XCTAssertEqual(s.title, "Real Title", "a root-level title should win over slug")
    }
}

import XCTest
@testable import Claudoscope

final class SessionTraceTests: XCTestCase {

    // MARK: - Fixtures

    private func records(_ lines: [String]) throws -> [ParsedRecordRaw] {
        let decoder = JSONDecoder()
        decoder.userInfo[.decodeMode] = DecodeMode.full
        return try lines.map { try decoder.decode(ParsedRecordRaw.self, from: Data($0.utf8)) }
    }

    private func ts(_ seconds: Int) -> String {
        let date = Date(timeIntervalSince1970: 1_790_000_000 + Double(seconds))
        return ISO8601.withFractional.string(from: date)
    }

    private func user(_ uuid: String, at seconds: Int, text: String = "do the thing") -> String {
        "{\"type\":\"user\",\"uuid\":\"\(uuid)\",\"timestamp\":\"\(ts(seconds))\",\"message\":{\"role\":\"user\",\"content\":\"\(text)\"}}"
    }

    private func toolResultUser(_ uuid: String, at seconds: Int, toolUseId: String) -> String {
        "{\"type\":\"user\",\"uuid\":\"\(uuid)\",\"timestamp\":\"\(ts(seconds))\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"\(toolUseId)\",\"content\":\"ok\"}]}}"
    }

    private func assistant(
        _ uuid: String, at seconds: Int,
        toolUses: [(id: String, name: String, input: String)] = [],
        stopReason: String? = "end_turn",
        inputTokens: Int = 1000, outputTokens: Int = 100, cacheRead: Int = 0
    ) -> String {
        let stop = stopReason.map { "\"\($0)\"" } ?? "null"
        let blocks = toolUses.map {
            "{\"type\":\"tool_use\",\"id\":\"\($0.id)\",\"name\":\"\($0.name)\",\"input\":\($0.input)}"
        }.joined(separator: ",")
        let usage = "{\"input_tokens\":\(inputTokens),\"output_tokens\":\(outputTokens),\"cache_read_input_tokens\":\(cacheRead)}"
        return "{\"type\":\"assistant\",\"uuid\":\"\(uuid)\",\"timestamp\":\"\(ts(seconds))\",\"message\":{\"role\":\"assistant\",\"id\":\"m-\(uuid)\",\"model\":\"claude-opus-5-5\",\"stop_reason\":\(stop),\"usage\":\(usage),\"content\":[\(blocks)]}}"
    }

    private func compaction(_ uuid: String, at seconds: Int) -> String {
        "{\"type\":\"system\",\"subtype\":\"compact_boundary\",\"uuid\":\"\(uuid)\",\"timestamp\":\"\(ts(seconds))\",\"compactMetadata\":{\"trigger\":\"auto\",\"preTokens\":100000}}"
    }

    private func session(_ records: [ParsedRecordRaw], results: [String: ToolResultEntry] = [:]) -> ParsedSession {
        let metadata = SessionMetadata(
            firstTimestamp: "", lastTimestamp: "", messageCount: records.count,
            userMessageCount: 0, assistantMessageCount: 0,
            totalInputTokens: 0, totalOutputTokens: 0, totalCacheReadTokens: 0, totalCacheCreationTokens: 0,
            models: [], compactionCount: 0, turnDurations: [], effortDistribution: .zero,
            maxIdleGapSeconds: 0, idleGapAfterTimestamp: nil, compactionEvents: [],
            parallelToolGroups: [], errorDetails: []
        )
        return ParsedSession(
            id: "s", projectId: "p", slug: nil, records: records,
            toolResultMap: results, metadata: metadata, parentSessionId: nil
        )
    }

    private func build(_ lines: [String], results: [String: ToolResultEntry] = [:]) throws -> SessionTrace {
        let s = session(try records(lines), results: results)
        return try XCTUnwrap(SessionTrace.build(for: s, blockedToolUseIds: [], pricingTable: PricingTables.anthropic))
    }

    // MARK: - Lanes

    func testTurnsSpansAndToolCalls() throws {
        let trace = try build([
            user("u1", at: 0, text: "fix the bug"),
            assistant("a1", at: 5, toolUses: [("t1", "Read", "{\"file_path\":\"/x.swift\"}")], stopReason: "tool_use"),
            toolResultUser("r1", at: 9, toolUseId: "t1"),
            assistant("a2", at: 20),
            user("u2", at: 60, text: "thanks"),
            assistant("a3", at: 70),
        ])
        XCTAssertEqual(trace.userTurns.map(\.turnNumber), [1, 2])
        XCTAssertEqual(trace.userTurns[0].label, "fix the bug")
        XCTAssertEqual(trace.claudeSpans.count, 2)
        XCTAssertEqual(trace.claudeSpans[0].toolCallCount, 1)
        XCTAssertEqual(trace.claudeSpans[0].end.timeIntervalSince(trace.claudeSpans[0].start), 20, accuracy: 0.01)
        XCTAssertEqual(trace.toolCalls.map(\.category), [.read])
        XCTAssertEqual(trace.toolCalls[0].label, "Read: /x.swift")
        XCTAssertEqual(trace.duration, 70, accuracy: 0.01)
    }

    func testToolResultTimestampExtendsTheSpan() throws {
        let trace = try build(
            [
                user("u1", at: 0),
                assistant("a1", at: 2, toolUses: [("t1", "Bash", "{\"command\":\"make\"}")], stopReason: "tool_use"),
            ],
            results: ["t1": ToolResultEntry(content: "", isError: false, timestamp: ts(600))]
        )
        XCTAssertEqual(trace.claudeSpans.count, 1)
        XCTAssertEqual(trace.claudeSpans[0].end.timeIntervalSince(trace.start), 600, accuracy: 0.01)
        XCTAssertTrue(trace.gaps.isEmpty, "a long tool run is busy, not idle")
    }

    func testErrorsAndCompactionsAreMarked() throws {
        let trace = try build(
            [
                user("u1", at: 0),
                assistant("a1", at: 1, toolUses: [("t1", "Bash", "{\"command\":\"false\"}")], stopReason: "tool_use"),
                compaction("c1", at: 30),
                assistant("a2", at: 40),
            ],
            results: ["t1": ToolResultEntry(content: "exit 1", isError: true, timestamp: nil)]
        )
        XCTAssertTrue(trace.toolCalls[0].isError)
        XCTAssertEqual(trace.compactions.count, 1)
        XCTAssertEqual(trace.compactions[0].time.timeIntervalSince(trace.start), 30, accuracy: 0.01)
    }

    func testCostAccumulatesPerBilledMessage() throws {
        let trace = try build([
            user("u1", at: 0),
            assistant("a1", at: 1, stopReason: nil, inputTokens: 1_000_000, outputTokens: 0),
            assistant("a2", at: 2, inputTokens: 1_000_000, outputTokens: 0),
            assistant("a3", at: 3, inputTokens: 0, outputTokens: 1_000_000),
        ])
        XCTAssertEqual(trace.costPoints.count, 2, "streaming intermediates without stop_reason are not billed")
        XCTAssertEqual(trace.costPoints[0].cumulative, 4, accuracy: 0.0001)
        XCTAssertEqual(trace.totalCost, 24, accuracy: 0.0001)
        XCTAssertEqual(trace.cost(at: trace.start.addingTimeInterval(2.5)), 4, accuracy: 0.0001)
        XCTAssertEqual(trace.models, ["claude-opus-5-5"])
    }

    // MARK: - Agents

    func testConcurrentAgentsStackOntoRows() throws {
        let trace = try build(
            [
                user("u1", at: 0),
                assistant("a1", at: 1, toolUses: [
                    ("g1", "Agent", "{\"description\":\"explore\"}"),
                    ("g2", "Agent", "{\"description\":\"research\"}"),
                ], stopReason: "tool_use"),
                assistant("a2", at: 100, toolUses: [("g3", "Agent", "{\"description\":\"later\"}")], stopReason: "tool_use"),
            ],
            results: [
                "g1": ToolResultEntry(content: "", isError: false, timestamp: ts(50)),
                "g2": ToolResultEntry(content: "", isError: false, timestamp: ts(80)),
            ]
        )
        XCTAssertEqual(trace.agentSpans.map(\.label), ["explore", "research", "later"])
        XCTAssertEqual(trace.agentSpans.map(\.row), [0, 1, 0])
        XCTAssertEqual(trace.agentRowCount, 2)
        XCTAssertNil(trace.agentSpans[2].end)
    }

    // MARK: - Gaps and axis

    func testIdleGapIsDetectedAndCollapsed() throws {
        let trace = try build([
            user("u1", at: 0),
            assistant("a1", at: 10),
            user("u2", at: 3610),
            assistant("a2", at: 3620),
        ])
        XCTAssertEqual(trace.gaps.count, 1)
        XCTAssertEqual(trace.gaps[0].duration, 3600, accuracy: 0.01)
        XCTAssertEqual(trace.activeDuration, 20, accuracy: 0.01)

        let collapsed = TraceTimeAxis(trace: trace, collapsesGaps: true)
        XCTAssertEqual(collapsed.virtualDuration, 20 + TraceTimeAxis.collapsedGapSeconds, accuracy: 0.01)
        XCTAssertEqual(collapsed.fraction(of: trace.start), 0)
        XCTAssertEqual(collapsed.fraction(of: trace.end), 1)
        let secondTurn = trace.userTurns[1].time
        XCTAssertEqual(collapsed.fraction(of: secondTurn), 40 / 50, accuracy: 0.001)

        let expanded = TraceTimeAxis(trace: trace, collapsesGaps: false)
        XCTAssertEqual(expanded.fraction(of: secondTurn), 3610 / 3620, accuracy: 0.001)
    }

    func testAxisRoundTripsThroughGaps() throws {
        let trace = try build([
            user("u1", at: 0),
            assistant("a1", at: 10),
            user("u2", at: 1000),
            assistant("a2", at: 1010),
            user("u3", at: 5000),
            assistant("a3", at: 5010),
        ])
        XCTAssertEqual(trace.gaps.count, 2)
        let axis = TraceTimeAxis(trace: trace, collapsesGaps: true)
        for seconds in [0.0, 5, 10, 300, 1000, 1005, 2000, 5000, 5010] {
            let date = trace.start.addingTimeInterval(seconds)
            let back = axis.date(atFraction: axis.fraction(of: date))
            XCTAssertEqual(back.timeIntervalSince(date), 0, accuracy: 0.5, "round trip at \(seconds)s")
        }
        XCTAssertEqual(axis.gapFractions.count, 2)
    }

    func testSessionWithoutTimestampsHasNoTrace() throws {
        let s = session(try records([
            "{\"type\":\"user\",\"uuid\":\"u1\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}",
        ]))
        XCTAssertNil(SessionTrace.build(for: s, blockedToolUseIds: [], pricingTable: PricingTables.anthropic))
    }
}

import XCTest
@testable import Claudoscope

final class SessionMinimapTests: XCTestCase {

    // MARK: - Fixtures

    private func records(_ lines: [String]) throws -> [ParsedRecordRaw] {
        let decoder = JSONDecoder()
        decoder.userInfo[.decodeMode] = DecodeMode.full
        return try lines.map { try decoder.decode(ParsedRecordRaw.self, from: Data($0.utf8)) }
    }

    private func user(uuid: String, text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "{\"type\":\"user\",\"uuid\":\"\(uuid)\",\"timestamp\":\"2026-10-06T10:00:00.000Z\",\"message\":{\"role\":\"user\",\"content\":\"\(escaped)\"}}"
    }

    private func assistant(uuid: String, toolUses: [(id: String, name: String, input: String)], stopReason: String? = "tool_use") -> String {
        let stop = stopReason.map { "\"\($0)\"" } ?? "null"
        let blocks = toolUses.map {
            "{\"type\":\"tool_use\",\"id\":\"\($0.id)\",\"name\":\"\($0.name)\",\"input\":\($0.input)}"
        }.joined(separator: ",")
        return "{\"type\":\"assistant\",\"uuid\":\"\(uuid)\",\"timestamp\":\"2026-10-06T10:00:01.000Z\",\"message\":{\"role\":\"assistant\",\"id\":\"m-\(uuid)\",\"model\":\"claude-opus-5\",\"stop_reason\":\(stop),\"content\":[\(blocks)]}}"
    }

    private func compaction(uuid: String) -> String {
        "{\"type\":\"system\",\"subtype\":\"compact_boundary\",\"uuid\":\"\(uuid)\",\"timestamp\":\"2026-10-06T10:00:02.000Z\",\"compactMetadata\":{\"trigger\":\"auto\",\"preTokens\":100000}}"
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

    private func kinds(_ events: [MinimapEvent]) -> [MinimapEventKind] { events.map(\.kind) }

    // MARK: - Tests

    func testTurnsAndToolCallsAreEmitted() throws {
        let s = session(try records([
            user(uuid: "u1", text: "fix the bug"),
            assistant(uuid: "a1", toolUses: [
                ("t1", "Read", "{\"file_path\":\"/x/y.swift\"}"),
                ("t2", "Bash", "{\"command\":\"swift build\"}"),
            ]),
        ]))
        let events = SessionMinimap.events(for: s, blockedToolUseIds: [])
        XCTAssertEqual(kinds(events), [.userTurn, .assistantTurn, .toolCall(.read), .toolCall(.exec)])
        XCTAssertEqual(events.map(\.recordIndex), [0, 1, 1, 1])
        XCTAssertEqual(events[2].label, "Read: /x/y.swift")
        XCTAssertEqual(events[3].label, "Bash: swift build")
        XCTAssertEqual(SessionMinimap.lane(for: .userTurn), 0)
        XCTAssertEqual(SessionMinimap.lane(for: .toolCall(.read)), 1)
        XCTAssertEqual(SessionMinimap.lane(for: .toolError), 2)
    }

    func testErrorAndBlockedAreMutuallyExclusive() throws {
        let s = session(
            try records([
                assistant(uuid: "a1", toolUses: [
                    ("t1", "Bash", "{\"command\":\"rm -rf /\"}"),
                    ("t2", "Bash", "{\"command\":\"false\"}"),
                ]),
            ]),
            results: [
                "t1": ToolResultEntry(content: "The user doesn't want to proceed", isError: true, timestamp: nil),
                "t2": ToolResultEntry(content: "exit 1", isError: true, timestamp: nil),
            ]
        )
        let events = SessionMinimap.events(for: s, blockedToolUseIds: ["t1"])
        XCTAssertEqual(kinds(events), [.assistantTurn, .toolCall(.exec), .blocked, .toolCall(.exec), .toolError])
        XCTAssertFalse(events.contains { $0.kind == .toolError && $0.label.contains("rm -rf") })
    }

    func testCompactionAndAgentSpawn() throws {
        let s = session(try records([
            compaction(uuid: "c1"),
            assistant(uuid: "a1", toolUses: [
                ("t1", "Agent", "{\"description\":\"Explore the parser\",\"prompt\":\"...\"}"),
            ]),
        ]))
        let events = SessionMinimap.events(for: s, blockedToolUseIds: [])
        XCTAssertEqual(kinds(events), [.compaction, .assistantTurn, .toolCall(.exec), .subagentSpawn])
        XCTAssertEqual(events[0].recordIndex, 0)
        XCTAssertEqual(events[3].label, "Agent: Explore the parser")
    }

    func testHiddenUserRecordsAreSkipped() throws {
        let s = session(try records([
            user(uuid: "u1", text: "<system-reminder>\nnothing to see\n</system-reminder>"),
            user(uuid: "u2", text: "real prompt"),
        ]))
        let events = SessionMinimap.events(for: s, blockedToolUseIds: [])
        XCTAssertEqual(kinds(events), [.userTurn])
        XCTAssertEqual(events[0].recordIndex, 1)
    }

    func testStreamingIntermediateIsNotATurn() throws {
        let s = session(try records([
            assistant(uuid: "a0", toolUses: [], stopReason: nil),
            assistant(uuid: "a1", toolUses: [], stopReason: "end_turn"),
        ]))
        let events = SessionMinimap.events(for: s, blockedToolUseIds: [])
        XCTAssertEqual(kinds(events), [.assistantTurn])
        XCTAssertEqual(events[0].recordIndex, 1)
    }

    func testBookmarkMarkIsEmitted() throws {
        let s = session(try records([
            user(uuid: "u1", text: "first"),
            user(uuid: "u2", text: "second"),
        ]))
        let events = SessionMinimap.events(for: s, blockedToolUseIds: [], bookmarkedUuids: ["u2"])
        XCTAssertEqual(kinds(events), [.userTurn, .userTurn, .bookmark])
        XCTAssertEqual(events[2].recordIndex, 1)
        XCTAssertEqual(events[2].uuid, "u2")
        XCTAssertEqual(SessionMinimap.lane(for: .bookmark), 2)
    }
}

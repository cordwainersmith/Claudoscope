import XCTest
@testable import Claudoscope

/// `permissionDecision` and `sandboxed` on tool-result records (Claude Code
/// 2.1.29x+). Record shapes below are copied from real 2.1.318 transcripts.
final class PermissionDecisionTests: XCTestCase {

    private func write(_ lines: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-perm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("s1.jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let assistant = #"{"type":"assistant","uuid":"a1","sessionId":"s1","timestamp":"2026-11-01T10:00:00.000Z","message":{"role":"assistant","id":"msg_1","model":"claude-sonnet-4-6","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}],"usage":{"input_tokens":10,"output_tokens":10}}}"#

    private func result(_ uuid: String, decision: String, sandboxed: String = "false", denialKind: String? = nil,
                        timestamp: String = "2026-11-01T10:00:01.000Z", text: String = "ok", isError: Bool = false) -> String {
        let kind = denialKind.map { #","toolDenialKind":"\#($0)""# } ?? ""
        return #"{"type":"user","uuid":"\#(uuid)","sessionId":"s1","timestamp":"\#(timestamp)","permissionDecision":\#(decision),"sandboxed":\#(sandboxed)\#(kind),"toolUseResult":{"stdout":"\#(text)"},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t-\#(uuid)","content":"\#(text)","is_error":\#(isError)}]}}"#
    }

    private let acceptMode = #"{"decision":"accept","source":"config","reasonType":"mode"}"#
    private let acceptRule = #"{"decision":"accept","source":"config","reasonType":"rule"}"#
    private let userOnce = #"{"decision":"accept","source":"user_temporary"}"#
    private let safety = #"{"decision":"reject","source":"config","reasonType":"safetyCheck","reasonCode":"safetyCheck","circuitBreaker":"dangerousRemoval"}"#
    private let userReject = #"{"decision":"reject","source":"user_reject","reasonCode":"unknown"}"#
    private let denyRule = #"{"decision":"reject","source":"config","reasonType":"subcommandResults","ruleSource":"userSettings","reasonCode":"rule:userSettings"}"#

    private func summary(_ lines: [String]) async throws -> SessionSummary {
        try await SessionParser().parseMetadata(url: try write(lines), sessionId: "s1", pricingTable: PricingTables.anthropic)
    }

    // MARK: - Parser

    func testStatsFoldPerDay() async throws {
        let s = try await summary([
            assistant,
            result("r1", decision: acceptMode),
            result("r2", decision: acceptMode, sandboxed: "true"),
            result("r3", decision: acceptRule, sandboxed: "null"),
            result("r4", decision: userOnce),
            result("r5", decision: safety, text: "denied by a built-in Claude Code safety check", isError: true),
            result("r6", decision: denyRule, timestamp: "2026-11-02T09:00:00.000Z", isError: true),
        ])
        let day1 = try XCTUnwrap(s.dailyContributions.first { $0.date == ISO8601.localDayKey("2026-11-01T10:00:01.000Z") })
        let stats = try XCTUnwrap(day1.permissionStats)
        XCTAssertEqual(stats.decisions["accept|config|mode"], 2)
        XCTAssertEqual(stats.decisions["accept|config|rule"], 1)
        XCTAssertEqual(stats.decisions["accept|user_temporary|-"], 1)
        XCTAssertEqual(stats.decisions["reject|config|safetyCheck"], 1)
        XCTAssertEqual(stats.circuitBreakers, ["dangerousRemoval": 1])
        XCTAssertEqual(stats.sandboxed, 1)
        XCTAssertEqual(stats.unsandboxed, 3)

        let day2 = try XCTUnwrap(s.dailyContributions.first { $0.date == ISO8601.localDayKey("2026-11-02T09:00:00.000Z") })
        XCTAssertTrue(day2.isPermissionOnly)
        XCTAssertEqual(day2.permissionStats?.denyRuleSources, ["userSettings": 1])
        XCTAssertEqual(s.blockedActionCount, 2)
    }

    func testRejectWithDenialKindCountsOnce() async throws {
        let s = try await summary([
            assistant,
            result("r1", decision: userReject, denialKind: "user-rejected", isError: true),
        ])
        XCTAssertEqual(s.blockedActionCount, 1)
    }

    func testPermissionOnlyDayStaysOutOfSessionCounts() async throws {
        let s = try await summary([
            assistant,
            result("r1", decision: acceptMode, timestamp: "2026-11-02T09:00:00.000Z"),
        ])
        let project = Project(id: "p", name: "p", path: "/p", sessionCount: 1)
        let fromNov2 = Calendar.current.startOfDay(for: try XCTUnwrap(ISO8601.parse("2026-11-02T09:00:00.000Z")))
        let data = AnalyticsEngine.compute(sessions: [(s, project)], pricingTable: PricingTables.anthropic, from: fromNov2)
        XCTAssertEqual(data.totalSessions, 0, "a day with only a permission decision is not activity")
        XCTAssertEqual(data.permissionAnalytics.totalDecisions, 1)
    }

    // MARK: - Kinds

    func testBlockedKindFromPermissionDecision() {
        func kind(_ d: PermissionDecisionRaw) -> BlockedActionKind? {
            ObservabilityAnalyzer.blockedKind(fromPermissionDecision: d)
        }
        XCTAssertNil(kind(.init(decision: "accept", source: "config", reasonType: "mode")))
        XCTAssertEqual(kind(.init(decision: "reject", source: "user_reject")), .userRejected)
        XCTAssertEqual(kind(.init(decision: "reject", source: "config", reasonType: "safetyCheck")), .safetyCheck)
        XCTAssertEqual(kind(.init(decision: "reject", source: "config", reasonType: "mode")), .modeDenied)
        XCTAssertEqual(kind(.init(decision: "reject", source: "config", reasonType: "rule")), .permissionSetting)
        XCTAssertEqual(kind(.init(decision: "reject", source: "config", reasonType: "subcommandResults")), .permissionSetting)
        XCTAssertEqual(kind(.init(decision: "reject", source: "config", reasonType: "newThing")), .other)
        XCTAssertNil(ObservabilityAnalyzer.blockedKind(fromPermissionDecision: nil))
    }

    func testExtractBlockedActionsUsesDecisionAndKeepsDestructiveLabel() {
        func entry(_ id: String, _ command: String, _ d: PermissionDecisionRaw?) -> ToolCallEntry {
            ToolCallEntry(id: id, toolName: "Bash", category: toolCategory(for: "Bash"), input: [:],
                          primaryArg: command, resultContent: "Permission denied", isError: true,
                          turnIndex: 1, sessionId: "s1", timestamp: nil, permissionDecision: d)
        }
        let actions = ObservabilityAnalyzer.extractBlockedActions(from: [
            entry("a", "rm -rf build", .init(decision: "reject", source: "config", reasonType: "safetyCheck", circuitBreaker: "dangerousRemoval")),
            entry("b", "git reset --hard", .init(decision: "reject", source: "user_reject")),
            entry("c", "ls", .init(decision: "accept", source: "config", reasonType: "mode")),
        ])
        XCTAssertEqual(actions.map(\.kind), [.safetyCheck, .destructiveGit])
        XCTAssertTrue(actions[0].reason.hasSuffix("[dangerousRemoval]"))
    }

    // MARK: - Analytics

    func testPermissionAnalyticsLabelsAndShares() {
        var stats = PermissionStats()
        stats.record(.init(decision: "accept", source: "config", reasonType: "mode"), sandboxed: true)
        stats.record(.init(decision: "accept", source: "config", reasonType: "mode"), sandboxed: false)
        stats.record(.init(decision: "reject", source: "config", reasonType: "safetyCheck", circuitBreaker: "dangerousRemoval"), sandboxed: nil)
        stats.record(.init(decision: "reject", source: "user_reject"), sandboxed: nil)
        var day = DailyContribution(date: "2026-11-01", inputTokens: 0, outputTokens: 0, cacheReadTokens: 0,
                                    cacheCreationTokens: 0, cacheCreation5mTokens: 0, cacheCreation1hTokens: 0,
                                    estimatedCost: 0, modelBreakdown: [])
        day.permissionStats = stats
        let a = AnalyticsEngine.computePermissionAnalytics(days: [day])
        XCTAssertEqual(a.totalDecisions, 4)
        XCTAssertEqual(a.totalDenials, 2)
        XCTAssertEqual(a.approvalsBySource, [LabeledCount(label: "Permission mode", count: 2)])
        XCTAssertEqual(Set(a.denialsByReason.map(\.label)), ["Safety check", "You rejected"])
        XCTAssertEqual(a.safetyCheckTrips, 1)
        XCTAssertEqual(a.sandboxedShare ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(a.dailyDenials, [DatedCount(date: "2026-11-01", count: 2)])
    }

    func testUnknownLabelKeepsRawParts() {
        XCTAssertEqual(AnalyticsEngine.permissionLabel(decision: "accept", source: "hook", reasonType: "x"), "Other (hook/x)")
    }

    func testPermissionStatsLegacyDecode() throws {
        let stats = try JSONDecoder().decode(PermissionStats.self, from: Data(#"{"decisions":{"accept|config|mode":3}}"#.utf8))
        XCTAssertEqual(stats.decisions["accept|config|mode"], 3)
        XCTAssertEqual(stats.sandboxed, 0)
        XCTAssertTrue(stats.circuitBreakers.isEmpty)
    }
}

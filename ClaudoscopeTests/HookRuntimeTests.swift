import XCTest
@testable import Claudoscope

/// Hook runtime extraction: hook_success attachment records and
/// stop_hook_summary system records fold into SessionSummary.hookRunStats
/// during lite parse, and HookRuntimeEngine rolls them up across sessions.
final class HookRuntimeTests: XCTestCase {

    private func writeTempFile(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-hookrun-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func parse(_ lines: [String]) async throws -> SessionSummary {
        let url = try writeTempFile(lines)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await SessionParser().parseMetadata(
            url: url, sessionId: "sess-1", pricingTable: PricingTables.anthropic
        )
    }

    private let assistant = "{\"type\":\"assistant\",\"uuid\":\"u1\",\"sessionId\":\"sess-1\",\"timestamp\":\"2026-08-05T12:00:00.000Z\",\"message\":{\"role\":\"assistant\",\"id\":\"m1\",\"stop_reason\":\"end_turn\",\"model\":\"claude-opus-5\",\"usage\":{\"input_tokens\":100,\"output_tokens\":200,\"service_tier\":\"standard\"}}}"

    private func hookSuccess(command: String = "/Users/x/.claude/hooks/guard.sh", durationMs: Int = 120, exitCode: Int = 0) -> String {
        "{\"type\":\"attachment\",\"uuid\":\"a-\(UUID().uuidString)\",\"sessionId\":\"sess-1\",\"timestamp\":\"2026-08-05T12:01:00.000Z\",\"attachment\":{\"type\":\"hook_success\",\"hookName\":\"PreToolUse:Bash\",\"hookEvent\":\"PreToolUse\",\"toolUseID\":\"t1\",\"command\":\"\(command)\",\"durationMs\":\(durationMs),\"exitCode\":\(exitCode),\"stdout\":\"\",\"stderr\":\"\"}}"
    }

    private let stopHookSummary = "{\"type\":\"system\",\"subtype\":\"stop_hook_summary\",\"uuid\":\"s1\",\"sessionId\":\"sess-1\",\"timestamp\":\"2026-08-05T12:02:00.000Z\",\"hookCount\":2,\"hookInfos\":[{\"command\":\"notify.sh\",\"durationMs\":50},{\"command\":\"http://localhost:9999/hook\"}],\"hookErrors\":[\"ECONNREFUSED\"],\"hookAdditionalContext\":[],\"preventedContinuation\":false,\"stopReason\":\"\",\"hasOutput\":false,\"level\":\"suggestion\"}"

    // MARK: - Parse fold

    func testSessionWithoutHooksHasNilStats() async throws {
        let s = try await parse([assistant])
        XCTAssertNil(s.hookRunStats)
    }

    func testSingleHookSuccessAggregates() async throws {
        let s = try await parse([assistant, hookSuccess(durationMs: 120)])
        let stats = try XCTUnwrap(s.hookRunStats)
        XCTAssertEqual(stats.perCommand.count, 1)
        let cmd = stats.perCommand[0]
        XCTAssertEqual(cmd.hookName, "PreToolUse:Bash")
        XCTAssertEqual(cmd.fireCount, 1)
        XCTAssertEqual(cmd.errorCount, 0)
        XCTAssertEqual(cmd.totalDurationMs, 120)
        XCTAssertEqual(cmd.maxDurationMs, 120)
    }

    func testRepeatedCommandSumsAndTracksMax() async throws {
        let s = try await parse([assistant, hookSuccess(durationMs: 100), hookSuccess(durationMs: 300), hookSuccess(durationMs: 200)])
        let stats = try XCTUnwrap(s.hookRunStats)
        XCTAssertEqual(stats.perCommand.count, 1)
        XCTAssertEqual(stats.perCommand[0].fireCount, 3)
        XCTAssertEqual(stats.perCommand[0].totalDurationMs, 600)
        XCTAssertEqual(stats.perCommand[0].maxDurationMs, 300)
    }

    func testNonZeroExitCodeCountsAsError() async throws {
        let s = try await parse([assistant, hookSuccess(exitCode: 2), hookSuccess()])
        let stats = try XCTUnwrap(s.hookRunStats)
        XCTAssertEqual(stats.perCommand[0].fireCount, 2)
        XCTAssertEqual(stats.perCommand[0].errorCount, 1)
    }

    func testStopHookSummaryFolds() async throws {
        let s = try await parse([assistant, stopHookSummary])
        let stats = try XCTUnwrap(s.hookRunStats)
        XCTAssertEqual(stats.stopHookRuns, 1)
        XCTAssertEqual(stats.preventedContinuationCount, 0)
        let stopCommands = stats.perCommand.filter { $0.hookName == "Stop" }
        XCTAssertEqual(stopCommands.count, 2)
        XCTAssertEqual(stopCommands.reduce(0) { $0 + $1.fireCount }, 2)
        XCTAssertEqual(stopCommands.reduce(0) { $0 + $1.errorCount }, 1)
    }

    func testPreventedContinuationCounted() async throws {
        let prevented = stopHookSummary.replacingOccurrences(
            of: "\"preventedContinuation\":false", with: "\"preventedContinuation\":true"
        )
        let s = try await parse([assistant, prevented])
        XCTAssertEqual(s.hookRunStats?.preventedContinuationCount, 1)
    }

    /// Hook records carry no usage, so they must not shift billing.
    func testHookRecordsDoNotAffectBilling() async throws {
        let plain = try await parse([assistant])
        let hooked = try await parse([assistant, hookSuccess(), stopHookSummary])
        XCTAssertEqual(hooked.estimatedCost, plain.estimatedCost, accuracy: 1e-12)
        XCTAssertEqual(hooked.totalInputTokens, plain.totalInputTokens)
    }

    // MARK: - Cross-session engine

    private func summary(id: String, stats: HookRunStats?) -> SessionSummary {
        SessionSummary(
            id: id, projectId: "p", slug: nil, title: id,
            firstTimestamp: "2026-08-05T12:00:00.000Z", lastTimestamp: "2026-08-05T12:00:00.000Z",
            messageCount: 1, primaryModel: nil,
            totalInputTokens: 0, totalOutputTokens: 0, totalCacheReadTokens: 0,
            totalCacheCreationTokens: 0, totalCacheCreation5mTokens: 0, totalCacheCreation1hTokens: 0,
            compactionCount: 0, estimatedCost: 0, hasError: false,
            modelBreakdown: [], toolCallCount: 0, observability: .empty,
            isSubagent: false, dailyContributions: [],
            hookRunStats: stats
        )
    }

    private func cmdStats(hookName: String, command: String, fires: Int, errors: Int = 0) -> HookRunStats {
        HookRunStats(
            perCommand: [HookCommandRunStats(
                hookName: hookName, command: command,
                fireCount: fires, errorCount: errors,
                totalDurationMs: fires * 100, maxDurationMs: 100
            )],
            stopHookRuns: 0, preventedContinuationCount: 0
        )
    }

    private func hookGroups(commands: [String]) -> [HookEventGroup] {
        [HookEventGroup(event: "PreToolUse", rules: [
            HookRule(id: "r1", matcher: "*", hooks: commands.map {
                HookCommand(type: "command", command: $0, timeout: nil)
            }, source: .user)
        ])]
    }

    func testEngineAggregatesAcrossSessions() {
        let sessions = [
            summary(id: "s1", stats: cmdStats(hookName: "PreToolUse:Bash", command: "/x/guard.sh", fires: 3)),
            summary(id: "s2", stats: cmdStats(hookName: "PreToolUse:Bash", command: "/x/guard.sh", fires: 2, errors: 1)),
            summary(id: "s3", stats: nil),
        ]
        let aggs = HookRuntimeEngine.aggregate(sessions: sessions, hookGroups: hookGroups(commands: ["/x/guard.sh"]))
        XCTAssertEqual(aggs.count, 1)
        XCTAssertEqual(aggs[0].fireCount, 5)
        XCTAssertEqual(aggs[0].errorCount, 1)
        XCTAssertEqual(aggs[0].sessionCount, 2)
        XCTAssertTrue(aggs[0].isConfigured)
    }

    func testEngineExactMatchIsConfigured() {
        XCTAssertTrue(HookRuntimeEngine.isConfigured("/x/guard.sh", in: ["/x/guard.sh"]))
    }

    func testEngineSuffixMatchIsConfigured() {
        // Transcript records the expanded path; config holds a shorter form.
        XCTAssertTrue(HookRuntimeEngine.isConfigured("/Users/x/.claude/hooks/guard.sh", in: ["hooks/guard.sh"]))
        // And the reverse: config holds an env-var-prefixed longer form.
        XCTAssertTrue(HookRuntimeEngine.isConfigured("guard.sh", in: ["$CLAUDE_PROJECT_DIR/guard.sh"]))
    }

    func testEngineUnmatchedCommandIsNotConfigured() {
        XCTAssertFalse(HookRuntimeEngine.isConfigured("/x/deleted-hook.sh", in: ["/x/guard.sh"]))
        XCTAssertFalse(HookRuntimeEngine.isConfigured("", in: ["/x/guard.sh"]))
    }
}

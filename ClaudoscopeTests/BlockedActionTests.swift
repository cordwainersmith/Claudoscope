import XCTest
@testable import Claudoscope

/// Tests for blocked/denied action detection and classification. The
/// auto-mode-vs-user distinction is not recoverable from the transcript, so
/// classification keys off the 2.1.183 destructive command patterns and falls
/// back to a generic user-rejected kind.
final class BlockedActionTests: XCTestCase {

    private func entry(tool: String, command: String?, result: String?, isError: Bool) -> ToolCallEntry {
        ToolCallEntry(
            id: UUID().uuidString,
            toolName: tool,
            category: toolCategory(for: tool),
            input: [:],
            primaryArg: command,
            resultContent: result,
            isError: isError,
            turnIndex: 0,
            sessionId: "s",
            timestamp: nil
        )
    }

    func testIsDenialRequiresErrorAndMarker() {
        XCTAssertTrue(ObservabilityAnalyzer.isDenial(
            resultContent: "The user doesn't want to proceed with this tool use.", isError: true))
        XCTAssertFalse(ObservabilityAnalyzer.isDenial(resultContent: "all good", isError: true))
        XCTAssertFalse(ObservabilityAnalyzer.isDenial(
            resultContent: "The user doesn't want to proceed with this tool use.", isError: false))
        XCTAssertFalse(ObservabilityAnalyzer.isDenial(resultContent: nil, isError: true))
    }

    func testClassifyDestructiveGit() {
        XCTAssertEqual(
            ObservabilityAnalyzer.classifyBlockedAction(
                toolName: "Bash", command: "git reset --hard origin/main", reason: "the user doesn't want"),
            .destructiveGit)
    }

    func testClassifyIaCDestroy() {
        XCTAssertEqual(
            ObservabilityAnalyzer.classifyBlockedAction(
                toolName: "Bash", command: "terraform destroy -auto-approve", reason: "x"),
            .iacDestroy)
    }

    func testClassifyPermissionSetting() {
        XCTAssertEqual(
            ObservabilityAnalyzer.classifyBlockedAction(
                toolName: "Read", command: nil,
                reason: "File is in a directory that is denied by your permission settings."),
            .permissionSetting)
    }

    func testClassifyUserRejectedFallback() {
        XCTAssertEqual(
            ObservabilityAnalyzer.classifyBlockedAction(
                toolName: "Edit", command: "foo.txt",
                reason: "The user doesn't want to take this action right now."),
            .userRejected)
    }

    func testExtractBlockedActionsFiltersAndClassifies() {
        let entries = [
            entry(tool: "Bash", command: "git reset --hard HEAD",
                  result: "The user doesn't want to proceed with this tool use.", isError: true),
            entry(tool: "Bash", command: "ls", result: "ok", isError: false),
            entry(tool: "Read", command: "/x",
                  result: "<tool_use_error>File is in a directory that is denied by your permission settings.</tool_use_error>",
                  isError: true)
        ]
        let blocked = ObservabilityAnalyzer.extractBlockedActions(from: entries)
        XCTAssertEqual(blocked.count, 2)
        XCTAssertEqual(blocked.first?.kind, .destructiveGit)
        XCTAssertEqual(blocked.last?.kind, .permissionSetting)
    }

    // MARK: - Real denial strings (CC 2.1.27x-2.1.28x)

    private func assertDenial(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(ObservabilityAnalyzer.isDenial(resultContent: text, isError: true), text, file: file, line: line)
    }

    func testAutoDeniedPromptsUnavailable() {
        assertDenial("Permission to use Bash has been auto-denied (prompts unavailable).")
    }

    func testPermissionForToolUseWasDenied() {
        assertDenial("Permission for this tool use was denied. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file).")
    }

    func testDontAskModeDenial() {
        assertDenial("Permission to use WebSearch has been denied because Claude Code is running in don't ask mode.")
    }

    func testBuiltInSafetyCheckDenial() {
        assertDenial("Permission for this command was denied by a built-in Claude Code safety check, not by the user.")
    }

    func testOutputRedirectionBlocked() {
        assertDenial("Output redirection to '/p/.env.example' was blocked by a deny rule.")
    }

    func testBareUserRejectedToolUse() {
        XCTAssertTrue(ObservabilityAnalyzer.isBareDenialResult("User rejected tool use"))
        XCTAssertFalse(ObservabilityAnalyzer.isDenial(resultContent: "User rejected tool use", isError: true),
                       "the short string carries no marker; only the bare-result path counts it")
        XCTAssertFalse(ObservabilityAnalyzer.isBareDenialResult("InputValidationError: file_path is required"))
    }

    func testToolDenialKindOnlyEntryIsBlocked() {
        var e = entry(tool: "Edit", command: "/p/a.swift", result: "something unrecognized", isError: true)
        e.toolDenialKind = "permission-rule"
        let blocked = ObservabilityAnalyzer.extractBlockedActions(from: [e])
        XCTAssertEqual(blocked.count, 1)
        XCTAssertEqual(blocked.first?.kind, .permissionSetting)
    }

    func testDenialKindMapping() {
        XCTAssertNil(ObservabilityAnalyzer.blockedKind(fromDenialKind: nil))
        XCTAssertEqual(ObservabilityAnalyzer.blockedKind(fromDenialKind: "user-rejected"), .userRejected)
        XCTAssertEqual(ObservabilityAnalyzer.blockedKind(fromDenialKind: "permission-rule"), .permissionSetting)
        XCTAssertEqual(ObservabilityAnalyzer.blockedKind(fromDenialKind: "classifier"), .other)
    }

    /// Lite path: the summary count picks up the new markers, the bare short
    /// string and a toolDenialKind-only record, and still ignores plain errors.
    func testParserBlockedCountCoversNewStringsAndDenialKind() async throws {
        func user(_ id: String, _ result: String, denialKind: String? = nil) -> String {
            let kind = denialKind.map { #","toolDenialKind":""# + $0 + #"""# } ?? ""
            return #"{"type":"user","uuid":""# + id + #"","sessionId":"s","timestamp":"2026-10-01T10:00:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t"# + id + #"","content":"x","is_error":true}]},"toolUseResult":"# + result + kind + "}"
        }
        let lines = [
            #"{"type":"assistant","uuid":"a1","sessionId":"s","timestamp":"2026-10-01T10:00:00.000Z","message":{"role":"assistant","id":"m1","model":"claude-sonnet-4-5","stop_reason":"end_turn","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":10,"output_tokens":5}}}"#,
            user("1", #""Error: Permission to use Bash has been auto-denied (prompts unavailable).""#),
            user("2", #""Error: Permission for this tool use was denied. The tool use was rejected.""#),
            user("3", #""User rejected tool use""#),
            user("4", #""Error: Permission for this command was denied by a built-in Claude Code safety check, not by the user.""#),
            user("5", #"{"stdout":"","stderr":"","interrupted":false}"#, denialKind: "permission-rule"),
            user("6", #""Error: Exit code 1""#),
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("blocked-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = try await SessionParser().parseMetadata(url: url, sessionId: "s", pricingTable: PricingTables.anthropic)
        XCTAssertEqual(summary.blockedActionCount, 5)
    }
}

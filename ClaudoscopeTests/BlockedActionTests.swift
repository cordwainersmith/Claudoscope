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
}

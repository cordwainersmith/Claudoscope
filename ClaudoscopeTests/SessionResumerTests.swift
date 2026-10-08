import XCTest
@testable import Claudoscope

final class SessionResumerTests: XCTestCase {

    func testShellQuoteEscapesSingleQuotes() {
        XCTAssertEqual(TerminalFocuser.shellQuote("it's"), "'it'\\''s'")
        XCTAssertEqual(TerminalFocuser.shellQuote("/plain/path"), "'/plain/path'")
    }

    func testSessionIdValidation() {
        XCTAssertTrue(SessionResumer.isValidSessionId("b2613ef7-1b2c-4d5e-8f90-123456789abc"))
        XCTAssertTrue(SessionResumer.isValidSessionId("agent-acompact-1a2b3c"))
        XCTAssertFalse(SessionResumer.isValidSessionId("x; rm -rf ~"))
        XCTAssertFalse(SessionResumer.isValidSessionId(""))
        XCTAssertFalse(SessionResumer.isValidSessionId("abc def"))
        XCTAssertFalse(SessionResumer.isValidSessionId("abc\"def"))
        XCTAssertEqual(SessionResumer.command(forSessionId: "abc"), "claude --resume abc")
    }

    func testRunScriptPerTerminal() {
        let dir = "/Users/me/projects/it's here"
        let command = SessionResumer.command(forSessionId: "abc-123")
        for bundleId in ["com.mitchellh.ghostty", "com.googlecode.iterm2", "com.apple.Terminal"] {
            let script = TerminalFocuser.runScript(bundleId: bundleId, command: command, workingDirectory: dir)
            XCTAssertNotNil(script, bundleId)
            XCTAssertTrue(script?.contains("claude --resume abc-123") == true, bundleId)
            if bundleId == "com.mitchellh.ghostty" {
                XCTAssertTrue(script?.contains("set initial working directory of cfg to \"\(dir)\"") == true)
            } else {
                XCTAssertTrue(script?.contains("cd '/Users/me/projects/it'\\\\''s here' && claude --resume abc-123") == true, bundleId)
            }
        }
        XCTAssertNil(TerminalFocuser.runScript(bundleId: "com.example.unknown", command: command, workingDirectory: dir))
    }

    func testRunScriptEscapesDoubleQuotesForAppleScript() {
        let script = TerminalFocuser.runScript(
            bundleId: "com.apple.Terminal", command: "claude --resume x", workingDirectory: "/tmp/say \"hi\""
        )
        XCTAssertTrue(script?.contains("\\\"hi\\\"") == true)
    }

    func testWorkingDirectoryPrefersRecordCwd() throws {
        let decoder = JSONDecoder()
        decoder.userInfo[.decodeMode] = DecodeMode.full
        let lines = [
            "{\"type\":\"user\",\"uuid\":\"u0\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}",
            "{\"type\":\"user\",\"uuid\":\"u1\",\"cwd\":\"/Users/me/.claude/worktrees/feature-x\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}",
            "{\"type\":\"user\",\"uuid\":\"u2\",\"cwd\":\"/Users/me/projects/other\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}",
        ]
        let records = try lines.map { try decoder.decode(ParsedRecordRaw.self, from: Data($0.utf8)) }
        let metadata = SessionMetadata(
            firstTimestamp: "", lastTimestamp: "", messageCount: 3,
            userMessageCount: 3, assistantMessageCount: 0,
            totalInputTokens: 0, totalOutputTokens: 0, totalCacheReadTokens: 0, totalCacheCreationTokens: 0,
            models: [], compactionCount: 0, turnDurations: [], effortDistribution: .zero,
            maxIdleGapSeconds: 0, idleGapAfterTimestamp: nil, compactionEvents: [],
            parallelToolGroups: [], errorDetails: []
        )
        let session = ParsedSession(
            id: "s", projectId: "-Users-me-projects-main", slug: nil, records: records,
            toolResultMap: [:], metadata: metadata, parentSessionId: nil
        )
        XCTAssertEqual(SessionResumer.workingDirectory(from: session), "/Users/me/.claude/worktrees/feature-x")

        let empty = ParsedSession(
            id: "s", projectId: "p", slug: nil, records: [records[0]],
            toolResultMap: [:], metadata: metadata, parentSessionId: nil
        )
        XCTAssertNil(SessionResumer.workingDirectory(from: empty))
    }
}

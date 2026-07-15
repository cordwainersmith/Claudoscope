import XCTest
@testable import Claudoscope

/// Pure-logic tests for the notification engine and the service's pure static
/// helpers. Nothing here constructs `SessionNotificationService` (its init drains
/// the real spool dir) or touches the bundle-guarded posting.
final class SessionNotificationEngineTests: XCTestCase {

    // MARK: - isIdlePrompt

    func testIsIdlePromptDetectsIdle() {
        XCTAssertTrue(SessionNotificationEngine.isIdlePrompt(
            notificationType: "idle_prompt",
            message: "Claude is waiting for your input"))
    }

    func testIsIdlePromptRejectsRealBlocks() {
        XCTAssertFalse(SessionNotificationEngine.isIdlePrompt(
            notificationType: "permission_prompt", message: "Claude needs your permission"))
        XCTAssertFalse(SessionNotificationEngine.isIdlePrompt(
            notificationType: "elicitation_dialog", message: "MCP server asks..."))
        // Unknown/future types are treated as blocks (surfaced), not idle.
        XCTAssertFalse(SessionNotificationEngine.isIdlePrompt(
            notificationType: "some_future_type", message: nil))
    }

    func testIsIdlePromptNullTypeFallsBackToMessage() {
        // Null type + idle phrase -> idle (mirrors session-notify.sh).
        XCTAssertTrue(SessionNotificationEngine.isIdlePrompt(
            notificationType: nil, message: "Claude is waiting for your input"))
        // Null type + other message -> block.
        XCTAssertFalse(SessionNotificationEngine.isIdlePrompt(
            notificationType: nil, message: "Claude needs your permission"))
        // Null type + nil message -> block (default to surfacing).
        XCTAssertFalse(SessionNotificationEngine.isIdlePrompt(notificationType: nil, message: nil))
    }

    // MARK: - parseSpoolPayload

    func testParseSpoolPayloadFull() {
        let data = Data("""
        {"session_id":"abc","cwd":"/tmp/proj","transcript_path":"/x/projects/enc/abc.jsonl",\
        "notification_type":"permission_prompt","message":"hi","hook_event_name":"Notification"}
        """.utf8)
        let e = SessionNotificationEngine.parseSpoolPayload(data)
        XCTAssertEqual(e?.sessionId, "abc")
        XCTAssertEqual(e?.cwd, "/tmp/proj")
        XCTAssertEqual(e?.transcriptPath, "/x/projects/enc/abc.jsonl")
        XCTAssertEqual(e?.notificationType, "permission_prompt")
        XCTAssertEqual(e?.message, "hi")
        XCTAssertEqual(e?.hookEventName, "Notification")
    }

    func testParseSpoolPayloadStopEvent() {
        // A Stop payload carries hook_event_name but no notification_type/message.
        let data = Data(#"{"session_id":"s1","hook_event_name":"Stop","cwd":"/tmp/p"}"#.utf8)
        let e = SessionNotificationEngine.parseSpoolPayload(data)
        XCTAssertEqual(e?.sessionId, "s1")
        XCTAssertEqual(e?.hookEventName, "Stop")
        XCTAssertNil(e?.notificationType)
    }

    func testParseSpoolPayloadToleratesMissingKeys() {
        let e = SessionNotificationEngine.parseSpoolPayload(Data(#"{"session_id":"z"}"#.utf8))
        XCTAssertEqual(e?.sessionId, "z")
        XCTAssertNil(e?.notificationType)
        XCTAssertNil(e?.cwd)
        XCTAssertNil(e?.hookEventName)
    }

    func testParseSpoolPayloadRejectsGarbageAndMissingSession() {
        XCTAssertNil(SessionNotificationEngine.parseSpoolPayload(Data("nonsense".utf8)))
        XCTAssertNil(SessionNotificationEngine.parseSpoolPayload(Data(#"{"cwd":"/x"}"#.utf8)))
        XCTAssertNil(SessionNotificationEngine.parseSpoolPayload(Data(#"{"session_id":""}"#.utf8)))
    }

    // MARK: - Service pure helpers

    func testProjectIdFromTranscriptPath() {
        XCTAssertEqual(
            SessionNotificationService.projectId(forTranscriptPath:
                "/Users/x/.claude/projects/-Users-x-proj/abc.jsonl"),
            "-Users-x-proj")
        // Subagent path still resolves to the project dir (component after projects).
        XCTAssertEqual(
            SessionNotificationService.projectId(forTranscriptPath:
                "/Users/x/.claude/projects/-Users-x-proj/abc/subagents/s.jsonl"),
            "-Users-x-proj")
    }

    func testProjectLabelFromEncodedId() {
        XCTAssertEqual(
            SessionNotificationService.projectLabel(fromProjectId: "-Users-liranb-projects-Claudoscope"),
            "Claudoscope")
        // Hyphenated folder names are rejoined, not truncated to the last segment.
        XCTAssertEqual(
            SessionNotificationService.projectLabel(fromProjectId: "-Users-liranb-projects-fix-okta-callback-race"),
            "fix-okta-callback-race")
    }

    func testComposeLabel() {
        let sid = "7642af63-729e-4cb1-a3f7-a898d22806b5"
        // Raw session-id fallback is dropped -> folder only.
        XCTAssertEqual(
            SessionNotificationService.composeLabel(title: String(sid.prefix(8)), folder: "Claudoscope", sessionId: sid),
            "Claudoscope")
        // A real title is overlaid as "Title (folder)".
        XCTAssertEqual(
            SessionNotificationService.composeLabel(title: "Fix the parser", folder: "Claudoscope", sessionId: sid),
            "Fix the parser (Claudoscope)")
        // A title identical to the folder isn't duplicated.
        XCTAssertEqual(
            SessionNotificationService.composeLabel(title: "Claudoscope", folder: "Claudoscope", sessionId: sid),
            "Claudoscope")
        // No title -> folder only.
        XCTAssertEqual(
            SessionNotificationService.composeLabel(title: nil, folder: "Claudoscope", sessionId: sid),
            "Claudoscope")
    }
}

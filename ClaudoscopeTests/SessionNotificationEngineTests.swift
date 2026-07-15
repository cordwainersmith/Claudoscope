import XCTest
@testable import Claudoscope

/// Pure-logic tests for the notification engine and the service's pure static
/// helpers. Nothing here constructs `SessionNotificationService` (its init drains
/// the real spool dir and starts a timer) or touches the bundle-guarded posting.
final class SessionNotificationEngineTests: XCTestCase {

    // MARK: - isWaiting

    func testIsWaitingDropsIdle() {
        XCTAssertFalse(SessionNotificationEngine.isWaiting(
            notificationType: "idle_prompt",
            message: "Claude is waiting for your input"))
    }

    func testIsWaitingAcceptsRealBlocks() {
        XCTAssertTrue(SessionNotificationEngine.isWaiting(
            notificationType: "permission_prompt", message: "Claude needs your permission"))
        XCTAssertTrue(SessionNotificationEngine.isWaiting(
            notificationType: "elicitation_dialog", message: "MCP server asks..."))
        // Unknown/future types are treated as waiting (defensive).
        XCTAssertTrue(SessionNotificationEngine.isWaiting(
            notificationType: "some_future_type", message: nil))
    }

    func testIsWaitingNullTypeFallsBackToMessage() {
        // Null type + idle phrase -> not waiting (mirrors session-notify.sh).
        XCTAssertFalse(SessionNotificationEngine.isWaiting(
            notificationType: nil, message: "Claude is waiting for your input"))
        // Null type + other message -> waiting.
        XCTAssertTrue(SessionNotificationEngine.isWaiting(
            notificationType: nil, message: "Claude needs your permission"))
        // Null type + nil message -> waiting (default to surfacing).
        XCTAssertTrue(SessionNotificationEngine.isWaiting(notificationType: nil, message: nil))
    }

    // MARK: - parseSpoolPayload

    func testParseSpoolPayloadFull() {
        let data = Data("""
        {"session_id":"abc","cwd":"/tmp/proj","transcript_path":"/x/projects/enc/abc.jsonl",\
        "notification_type":"permission_prompt","message":"hi"}
        """.utf8)
        let e = SessionNotificationEngine.parseSpoolPayload(data)
        XCTAssertEqual(e?.sessionId, "abc")
        XCTAssertEqual(e?.cwd, "/tmp/proj")
        XCTAssertEqual(e?.transcriptPath, "/x/projects/enc/abc.jsonl")
        XCTAssertEqual(e?.notificationType, "permission_prompt")
        XCTAssertEqual(e?.message, "hi")
    }

    func testParseSpoolPayloadToleratesMissingKeys() {
        let e = SessionNotificationEngine.parseSpoolPayload(Data(#"{"session_id":"z"}"#.utf8))
        XCTAssertEqual(e?.sessionId, "z")
        XCTAssertNil(e?.notificationType)
        XCTAssertNil(e?.cwd)
    }

    func testParseSpoolPayloadRejectsGarbageAndMissingSession() {
        XCTAssertNil(SessionNotificationEngine.parseSpoolPayload(Data("nonsense".utf8)))
        XCTAssertNil(SessionNotificationEngine.parseSpoolPayload(Data(#"{"cwd":"/x"}"#.utf8)))
        XCTAssertNil(SessionNotificationEngine.parseSpoolPayload(Data(#"{"session_id":""}"#.utf8)))
    }

    // MARK: - completedSessionsToFire

    private func snapshot(
        span: Double,
        quietSeconds: Double,
        fired: Bool = false,
        waiting: Bool = false,
        now: Date
    ) -> SessionNotificationEngine.ActivitySnapshot {
        .init(
            spanSeconds: span,
            lastActivityWall: now.addingTimeInterval(-quietSeconds),
            projectId: "p",
            firedCompleted: fired,
            waitingSince: waiting ? now : nil
        )
    }

    func testCompletedFiresWhenLongAndQuiet() {
        let now = Date()
        let activity = ["a": snapshot(span: 11 * 60, quietSeconds: 4 * 60, now: now)]
        XCTAssertEqual(SessionNotificationEngine.completedSessionsToFire(activity, now: now), ["a"])
    }

    func testCompletedSuppressedWhenSpanTooShort() {
        let now = Date()
        let activity = ["a": snapshot(span: 9 * 60, quietSeconds: 4 * 60, now: now)]
        XCTAssertTrue(SessionNotificationEngine.completedSessionsToFire(activity, now: now).isEmpty)
    }

    func testCompletedSuppressedWhenNotQuietEnough() {
        let now = Date()
        let activity = ["a": snapshot(span: 11 * 60, quietSeconds: 2 * 60, now: now)]
        XCTAssertTrue(SessionNotificationEngine.completedSessionsToFire(activity, now: now).isEmpty)
    }

    func testCompletedSuppressedWhileWaiting() {
        let now = Date()
        let activity = ["a": snapshot(span: 11 * 60, quietSeconds: 4 * 60, waiting: true, now: now)]
        XCTAssertTrue(SessionNotificationEngine.completedSessionsToFire(activity, now: now).isEmpty)
    }

    func testCompletedSuppressedWhenAlreadyFired() {
        let now = Date()
        let activity = ["a": snapshot(span: 11 * 60, quietSeconds: 4 * 60, fired: true, now: now)]
        XCTAssertTrue(SessionNotificationEngine.completedSessionsToFire(activity, now: now).isEmpty)
    }

    // MARK: - Service pure helpers

    func testSpanSeconds() {
        let span = SessionNotificationService.spanSeconds(
            first: "2026-04-03T10:00:00.000Z",
            last: "2026-04-03T10:15:00.000Z")
        XCTAssertEqual(span, 900, accuracy: 1)
    }

    func testSpanSecondsGarbageIsZero() {
        XCTAssertEqual(SessionNotificationService.spanSeconds(first: "x", last: "y"), 0)
    }

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
    }
}

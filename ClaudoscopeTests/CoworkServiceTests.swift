import XCTest
@testable import Claudoscope

final class CoworkServiceTests: XCTestCase {
    private var tempRoot: URL!
    private var supportDir: URL!
    private var service: CoworkService!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-cowork-tests-\(UUID().uuidString)")
        supportDir = tempRoot.appendingPathComponent("Claude")
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        service = CoworkService(supportDir: supportDir)
    }

    override func tearDown() async throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try await super.tearDown()
    }

    // MARK: - Availability semantics

    func testNotConfigured_missingDiscoveryFile() async {
        let (availability, sessions) = await service.loadSessions()
        XCTAssertEqual(availability, .notConfigured)
        XCTAssertFalse(availability.isReady)
        XCTAssertTrue(sessions.isEmpty)
    }

    func testConfiguredButEmpty_discoveryPresentNoSessions() async throws {
        try writeDiscovery(ownerId: "owner-1")
        // Owner directory exists but contains no session JSON files.
        try FileManager.default.createDirectory(
            at: ownerDir(ownerId: "owner-1"),
            withIntermediateDirectories: true
        )

        let (availability, sessions) = await service.loadSessions()
        XCTAssertEqual(availability, .configuredButEmpty(ownerId: "owner-1"))
        XCTAssertFalse(availability.isReady, "isReady must reflect 'in use', not just 'configured'")
        XCTAssertTrue(sessions.isEmpty)
    }

    func testReady_atLeastOneSessionPresent() async throws {
        try writeDiscovery(ownerId: "owner-1")
        try writeSession(
            ownerId: "owner-1",
            projectId: "project-1",
            sessionId: "session-1",
            metadata: minimalMetadata(sessionId: "session-1", title: "T")
        )

        let (availability, sessions) = await service.loadSessions()
        XCTAssertEqual(availability, .ready(ownerId: "owner-1"))
        XCTAssertTrue(availability.isReady)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.title, "T")
    }

    // MARK: - Decode + sort

    func testLoadsSingleSession_metadataOnly() async throws {
        try writeDiscovery(ownerId: "owner-1")
        try writeSession(
            ownerId: "owner-1",
            projectId: "project-1",
            sessionId: "session-1",
            metadata: [
                "sessionId": "session-1",
                "processName": "test-name",
                "cliSessionId": "cli-123",
                "cwd": "/tmp/test",
                "createdAt": 1_777_308_153_966,
                "lastActivityAt": 1_777_309_776_078,
                "model": "claude-sonnet-4-6",
                "title": "Test Cowork Session",
                "initialMessage": "do the thing",
                "isArchived": false,
                "fsDetectedFiles": ["/tmp/test/out.pptx"],
                "slashCommands": [["name": "setup-cowork"]]
            ]
        )

        let (_, sessions) = await service.loadSessions()
        let s = try XCTUnwrap(sessions.first)
        XCTAssertEqual(s.sessionId, "session-1")
        XCTAssertEqual(s.projectId, "project-1")
        XCTAssertEqual(s.processName, "test-name")
        XCTAssertEqual(s.title, "Test Cowork Session")
        XCTAssertEqual(s.model, "claude-sonnet-4-6")
        XCTAssertEqual(s.cwd, "/tmp/test")
        XCTAssertEqual(s.detectedFiles, ["/tmp/test/out.pptx"])
        XCTAssertEqual(s.slashCommandNames, ["setup-cowork"])
        XCTAssertNil(s.transcriptURL, "no audit.jsonl on disk")
    }

    func testTimestampsParseFromMilliseconds() async throws {
        try writeDiscovery(ownerId: "o")
        try writeSession(
            ownerId: "o",
            projectId: "p",
            sessionId: "s",
            metadata: minimalMetadata(
                sessionId: "s",
                createdAt: 1_777_308_153_966,
                lastActivityAt: 1_777_309_776_078
            )
        )
        let (_, sessions) = await service.loadSessions()
        let s = try XCTUnwrap(sessions.first)
        XCTAssertEqual(s.createdAt?.timeIntervalSince1970 ?? 0, 1_777_308_153.966, accuracy: 0.01)
        XCTAssertEqual(s.lastActivityAt?.timeIntervalSince1970 ?? 0, 1_777_309_776.078, accuracy: 0.01)
    }

    func testEffectiveLastActivityUsesAuditMtimeWhenNewer() async throws {
        try writeDiscovery(ownerId: "o")
        // Metadata claims an old lastActivityAt; the audit.jsonl mtime will be now.
        let oldMs = 1_000_000_000_000.0  // 2001
        try writeSession(
            ownerId: "o",
            projectId: "p",
            sessionId: "s",
            metadata: minimalMetadata(sessionId: "s", lastActivityAt: oldMs),
            transcriptLines: [#"{"type":"user","_audit_timestamp":"t","uuid":"u"}"#]
        )

        let (_, sessions) = await service.loadSessions()
        let s = try XCTUnwrap(sessions.first)
        // Effective should be ~now (mtime), not the year-2001 metadata claim.
        XCTAssertGreaterThan(s.effectiveLastActivity.timeIntervalSince1970, oldMs / 1000 + 86_400)
    }

    func testCorruptMetadataIsSkipped_othersStillLoad() async throws {
        try writeDiscovery(ownerId: "o")
        try writeSession(
            ownerId: "o",
            projectId: "p",
            sessionId: "good",
            metadata: minimalMetadata(sessionId: "good", title: "Good")
        )
        // Hand-corrupt sibling
        try "{ not json".write(
            to: ownerDir(ownerId: "o")
                .appendingPathComponent("p")
                .appendingPathComponent("local_corrupt.json"),
            atomically: true,
            encoding: .utf8
        )

        let (availability, sessions) = await service.loadSessions()
        XCTAssertTrue(availability.isReady)
        XCTAssertEqual(sessions.count, 1, "corrupt session should be skipped, not block the rest")
        XCTAssertEqual(sessions.first?.title, "Good")
    }

    func testSortsByEffectiveLastActivityDescending() async throws {
        try writeDiscovery(ownerId: "o")
        try writeSession(
            ownerId: "o", projectId: "p", sessionId: "older",
            metadata: minimalMetadata(sessionId: "older", title: "Older", lastActivityAt: 1_000_000_000_000)
        )
        try writeSession(
            ownerId: "o", projectId: "p", sessionId: "newer",
            metadata: minimalMetadata(sessionId: "newer", title: "Newer", lastActivityAt: 2_000_000_000_000)
        )

        let (_, sessions) = await service.loadSessions()
        XCTAssertEqual(sessions.map(\.title), ["Newer", "Older"])
    }

    func testFsDetectedFilesAcceptsStringsAndDicts() async throws {
        try writeDiscovery(ownerId: "o")
        try writeSession(
            ownerId: "o", projectId: "p", sessionId: "s",
            metadata: [
                "sessionId": "s",
                "fsDetectedFiles": [
                    "/a/string.txt",
                    ["path": "/b/dict.txt"],
                    ["unrelated": "skipped"]
                ]
            ]
        )
        let (_, sessions) = await service.loadSessions()
        let s = try XCTUnwrap(sessions.first)
        XCTAssertEqual(s.detectedFiles, ["/a/string.txt", "/b/dict.txt"])
    }

    func testTranscriptURLNilWhenAuditMissing() async throws {
        try writeDiscovery(ownerId: "o")
        try writeSession(
            ownerId: "o", projectId: "p", sessionId: "s",
            metadata: minimalMetadata(sessionId: "s")
        )
        let (_, sessions) = await service.loadSessions()
        XCTAssertNil(sessions.first?.transcriptURL)
    }

    // MARK: - Transcript parsing

    func testLoadsParsedSession_withTranscript() async throws {
        try writeDiscovery(ownerId: "o")
        try writeSession(
            ownerId: "o", projectId: "p", sessionId: "s",
            metadata: minimalMetadata(sessionId: "s"),
            transcriptLines: [
                #"{"type":"user","_audit_timestamp":"2026-05-08T10:00:00.000Z","uuid":"u-1","session_id":"inner","message":{"role":"user","content":"hi"}}"#,
                #"{"type":"assistant","_audit_timestamp":"2026-05-08T10:00:01.000Z","uuid":"a-1","session_id":"inner","message":{"id":"msg_1","role":"assistant","model":"claude-sonnet-4-6","stop_reason":"end_turn","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":100,"output_tokens":50}}}"#
            ]
        )
        let (_, sessions) = await service.loadSessions()
        let session = try XCTUnwrap(sessions.first)
        let parsedOpt = await service.loadParsedSession(for: session)
        let parsed = try XCTUnwrap(parsedOpt)
        XCTAssertEqual(parsed.id, "s")
        XCTAssertEqual(parsed.projectId, "p")
        XCTAssertEqual(parsed.metadata.totalInputTokens, 100)
        XCTAssertEqual(parsed.metadata.totalOutputTokens, 50)
    }

    // MARK: - Helpers

    private func ownerDir(ownerId: String) -> URL {
        supportDir
            .appendingPathComponent("local-agent-mode-sessions")
            .appendingPathComponent(ownerId)
    }

    private func writeDiscovery(ownerId: String) throws {
        let url = supportDir.appendingPathComponent("cowork-enabled-cli-ops.json")
        let data = try JSONSerialization.data(withJSONObject: ["ownerAccountId": ownerId])
        try data.write(to: url)
    }

    private func writeSession(
        ownerId: String,
        projectId: String,
        sessionId: String,
        metadata: [String: Any],
        transcriptLines: [String] = []
    ) throws {
        let projectDir = ownerDir(ownerId: ownerId).appendingPathComponent(projectId)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let metadataURL = projectDir.appendingPathComponent("local_\(sessionId).json")
        let data = try JSONSerialization.data(withJSONObject: metadata)
        try data.write(to: metadataURL)

        if !transcriptLines.isEmpty {
            let sessionDir = projectDir.appendingPathComponent("local_\(sessionId)")
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            let body = transcriptLines.joined(separator: "\n") + "\n"
            try body.write(to: sessionDir.appendingPathComponent("audit.jsonl"), atomically: true, encoding: .utf8)
        }
    }

    private func minimalMetadata(
        sessionId: String,
        title: String? = nil,
        createdAt: Double? = nil,
        lastActivityAt: Double? = nil
    ) -> [String: Any] {
        var dict: [String: Any] = ["sessionId": sessionId]
        if let title { dict["title"] = title }
        if let createdAt { dict["createdAt"] = createdAt }
        if let lastActivityAt { dict["lastActivityAt"] = lastActivityAt }
        return dict
    }
}

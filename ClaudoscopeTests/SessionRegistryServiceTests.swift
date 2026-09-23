import XCTest
@testable import Claudoscope

final class SessionRegistryServiceTests: XCTestCase {
    private var claudeDir: URL!

    override func setUpWithError() throws {
        claudeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: claudeDir.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: claudeDir)
    }

    private func write(_ content: String, to relativePath: String) throws {
        let url = claudeDir.appendingPathComponent(relativePath)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Real shape from Claude Code 2.1.280, with this test's own pid so it is alive.
    private func liveEntry(sessionId: String, status: String, extra: String = "") -> String {
        """
        {"pid":\(getpid()),"sessionId":"\(sessionId)","cwd":"/Users/x/projects/demo","startedAt":1790169952143,"procStart":"Wed Sep 23 13:25:50 2026","version":"2.1.280","peerProtocol":1,"peerFeatures":["notify_idle"],"kind":"interactive","entrypoint":"cli","pidDomain":"darwin","messagingSocketPath":"/tmp/cc-socks/1.sock","name":"demo-19","nameSource":"derived","nameSince":1790169952143,"status":"\(status)","updatedAt":1790172180544,"statusUpdatedAt":1790172180544\(extra)}
        """
    }

    func testDecodesLiveEntryAndIgnoresUnknownKeys() async throws {
        try write(liveEntry(sessionId: "s1", status: "waiting", extra: ",\"waitingFor\":\"input needed\""),
                  to: "sessions/\(getpid()).json")
        let entries = await SessionRegistryService(claudeDir: claudeDir).loadEntries()
        XCTAssertEqual(entries.count, 1)
        let e = try XCTUnwrap(entries.first)
        XCTAssertEqual(e.sessionId, "s1")
        XCTAssertEqual(e.status, "waiting")
        XCTAssertEqual(e.waitingFor, "input needed")
        XCTAssertEqual(e.kind, "interactive")
        XCTAssertEqual(e.cwdFolderName, "demo")
        XCTAssertFalse(e.isBackground)
    }

    func testBackgroundEntryCarriesJobId() async throws {
        let json = """
        {"pid":\(getpid()),"sessionId":"s2","cwd":"/tmp/p","startedAt":1,"kind":"bg","jobId":"eaa339a9","status":"idle","statusUpdatedAt":2}
        """
        try write(json, to: "sessions/\(getpid()).json")
        let entries = await SessionRegistryService(claudeDir: claudeDir).loadEntries()
        XCTAssertEqual(entries.first?.jobId, "eaa339a9")
        XCTAssertEqual(entries.first?.isBackground, true)
    }

    func testDeadPidIsFiltered() async throws {
        let json = """
        {"pid":99999999,"sessionId":"dead","status":"busy"}
        """
        try write(json, to: "sessions/99999999.json")
        let entries = await SessionRegistryService(claudeDir: claudeDir).loadEntries()
        XCTAssertTrue(entries.isEmpty)
    }

    func testMalformedAndKeyFilesAreSkipped() async throws {
        try write("{not json", to: "sessions/\(getpid()).json")
        // A .key sibling with unreadable permissions: if the service ever opened
        // it the read would fail loudly, but it must not be considered at all.
        let keyURL = claudeDir.appendingPathComponent("sessions/\(getpid()).abcdef.key")
        try "{\"peerToken\":\"secret\"}".write(to: keyURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: keyURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path) }
        let entries = await SessionRegistryService(claudeDir: claudeDir).loadEntries()
        XCTAssertTrue(entries.isEmpty)
    }

    func testRegistryFileNameFilter() {
        XCTAssertTrue(SessionRegistryService.isRegistryFileName("56010.json"))
        XCTAssertFalse(SessionRegistryService.isRegistryFileName("56010.abc.key"))
        XCTAssertFalse(SessionRegistryService.isRegistryFileName("state.json"))
        XCTAssertFalse(SessionRegistryService.isRegistryFileName(".json"))
    }

    func testIsAlive() {
        XCTAssertTrue(SessionRegistryService.isAlive(pid: Int(getpid())))
        XCTAssertFalse(SessionRegistryService.isAlive(pid: 99999999))
        XCTAssertFalse(SessionRegistryService.isAlive(pid: 0))
    }

    func testMissingDirectoryYieldsEmpty() async {
        let entries = await SessionRegistryService(claudeDir: URL(fileURLWithPath: "/nonexistent-\(UUID())")).loadEntries()
        XCTAssertTrue(entries.isEmpty)
    }
}

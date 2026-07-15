import XCTest
@testable import Claudoscope

/// Records gate-closure calls on the main actor for the install-gate test.
@MainActor
private final class GateRecorder {
    var calls: [Bool] = []
    func record(_ value: Bool) { calls.append(value) }
}

/// Exercises `NotificationHookInstaller` against a temporary `~/.claude/`.
/// Unlike `HardeningInstaller`, the hook script is inline (no `Bundle`), so the
/// full install/uninstall happy path runs under `swift test`.
@MainActor
final class NotificationHookInstallerTests: XCTestCase {
    var tempDir: URL!
    var installer: NotificationHookInstaller!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NotifHookTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        installer = NotificationHookInstaller(claudeDir: tempDir, setInstallInProgress: { _ in })
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - Helpers

    private var settingsURL: URL { tempDir.appendingPathComponent("settings.json") }

    private func writeJSON(_ obj: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
        try data.write(to: url)
    }

    private func readSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: settingsURL)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func seedSessionNotify() throws {
        let sn = tempDir.appendingPathComponent("hooks/session-notify.sh").path
        let boost = tempDir.appendingPathComponent("hooks/boost-sync.sh").path
        try writeJSON([
            "hooks": [
                "Notification": [
                    ["matcher": "", "hooks": [["type": "command", "command": sn]]],
                ],
                "Stop": [
                    ["matcher": "", "hooks": [["type": "command", "command": sn]]],
                    ["hooks": [[String: Any]]()],
                    ["hooks": [["type": "command", "command": boost]]],
                ],
            ],
        ], to: settingsURL)
    }

    // MARK: - Detection

    func testDetectExistingSessionNotify() async throws {
        let none = await installer.detectExistingSessionNotify()
        XCTAssertFalse(none)
        try seedSessionNotify()
        let found = await installer.detectExistingSessionNotify()
        XCTAssertTrue(found)
    }

    // MARK: - Install

    func testInstallStripsSessionNotifyAndRegistersOurHook() async throws {
        try seedSessionNotify()
        try await installer.install()

        let settings = try readSettings()

        XCTAssertTrue(
            NotificationHookInstaller.collectHookTriples(basename: "session-notify.sh", in: settings).isEmpty,
            "session-notify.sh must be stripped")

        let ours = NotificationHookInstaller.collectHookTriples(basename: "claudoscope-notify.sh", in: settings)
        XCTAssertEqual(ours.count, 1)
        XCTAssertEqual(ours.first?["event"], "Notification")

        XCTAssertFalse(
            NotificationHookInstaller.collectHookTriples(basename: "boost-sync.sh", in: settings).isEmpty,
            "unrelated boost-sync.sh must be preserved")

        // Pre-existing empty Stop entry preserved.
        let stop = settings["hooks"] as? [String: Any]
        let stopEntries = (stop?["Stop"] as? [[String: Any]]) ?? []
        XCTAssertTrue(stopEntries.contains { ($0["hooks"] as? [[String: Any]])?.isEmpty ?? false })

        // Hook script installed + executable.
        let scriptURL = tempDir.appendingPathComponent("hooks/claudoscope-notify.sh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptURL.path))
        let perms = (try FileManager.default.attributesOfItem(atPath: scriptURL.path)[.posixPermissions] as? NSNumber)?.int16Value ?? 0
        XCTAssertEqual(perms & 0o111, 0o111, "hook script must be executable")

        // Spool dir pre-created.
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent(".claudoscope-events").path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)

        // Marker records the two removed session-notify entries.
        let marker = try JSONSerialization.jsonObject(
            with: Data(contentsOf: tempDir.appendingPathComponent(".claudoscope-notify-installed"))) as! [String: Any]
        let removed = marker["removedSessionNotify"] as? [[String: Any]] ?? []
        XCTAssertEqual(removed.count, 2)
    }

    func testInstallOnEmptyDirRegistersHook() async throws {
        try await installer.install()
        let settings = try readSettings()
        XCTAssertEqual(
            NotificationHookInstaller.collectHookTriples(basename: "claudoscope-notify.sh", in: settings).count, 1)
    }

    func testInstallIsIdempotent() async throws {
        try await installer.install()
        try await installer.install()
        let settings = try readSettings()
        XCTAssertEqual(
            NotificationHookInstaller.collectHookTriples(basename: "claudoscope-notify.sh", in: settings).count, 1,
            "re-install must not duplicate the hook")
    }

    func testInstallRefusesMalformedSettings() async throws {
        try "{not json}".write(to: settingsURL, atomically: true, encoding: .utf8)

        var caught: Error?
        do { try await installer.install() } catch { caught = error }
        XCTAssertTrue(caught is NotificationHookInstallError, "expected malformed error, got \(String(describing: caught))")

        XCTAssertEqual(try String(contentsOf: settingsURL, encoding: .utf8), "{not json}",
                       "malformed settings must be left untouched")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("hooks/claudoscope-notify.sh").path),
            "no hook script should be written when settings is malformed")
    }

    func testInstallTogglesGate() async throws {
        let recorder = GateRecorder()
        let inst = NotificationHookInstaller(claudeDir: tempDir, setInstallInProgress: { v in recorder.record(v) })
        try await inst.install()
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(recorder.calls, [true, false])
    }

    // MARK: - Uninstall

    func testUninstallRestoresSessionNotify() async throws {
        try seedSessionNotify()
        try await installer.install()
        try await installer.uninstall()

        let settings = try readSettings()
        XCTAssertTrue(
            NotificationHookInstaller.collectHookTriples(basename: "claudoscope-notify.sh", in: settings).isEmpty,
            "our hook must be removed")

        let restored = NotificationHookInstaller.collectHookTriples(basename: "session-notify.sh", in: settings)
        XCTAssertEqual(restored.count, 2, "session-notify.sh must be restored under Notification and Stop")
        XCTAssertEqual(Set(restored.compactMap { $0["event"] }), ["Notification", "Stop"])

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("hooks/claudoscope-notify.sh").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent(".claudoscope-notify-installed").path))
    }

    func testUninstallRestoresFromBackupWhenMarkerMissing() async throws {
        try seedSessionNotify()
        try await installer.install()

        // Simulate a lost/corrupt marker.
        try FileManager.default.removeItem(at: tempDir.appendingPathComponent(".claudoscope-notify-installed"))

        try await installer.uninstall()

        let settings = try readSettings()
        let restored = NotificationHookInstaller.collectHookTriples(basename: "session-notify.sh", in: settings)
        XCTAssertEqual(restored.count, 2, "session-notify.sh must be restored from the settings backup")
    }

    func testUninstallOnEmptyDirIsNoop() async throws {
        try await installer.uninstall()
        // No settings file was created.
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))
    }

    // MARK: - End-to-end bridge (generated bash + parse contract)

    /// The installed hook script, fed a real Notification payload on stdin, must
    /// write exactly one `.json` spool file that `parseSpoolPayload` accepts.
    func testGeneratedHookScriptWritesParseableSpoolFile() async throws {
        try await installer.install()
        let scriptURL = tempDir.appendingPathComponent("hooks/claudoscope-notify.sh")
        let spool = tempDir.appendingPathComponent(".claudoscope-events")

        let payload = #"{"session_id":"abc","notification_type":"permission_prompt","message":"Claude needs your permission"}"#
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptURL.path]
        let stdin = Pipe()
        proc.standardInput = stdin
        try proc.run()
        stdin.fileHandleForWriting.write(Data(payload.utf8))
        try stdin.fileHandleForWriting.close()
        proc.waitUntilExit()

        let jsonFiles = try FileManager.default
            .contentsOfDirectory(at: spool, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertEqual(jsonFiles.count, 1, "hook must write exactly one .json spool file")

        let event = SessionNotificationEngine.parseSpoolPayload(try Data(contentsOf: jsonFiles[0]))
        XCTAssertEqual(event?.sessionId, "abc")
        XCTAssertEqual(event?.notificationType, "permission_prompt")
        XCTAssertFalse(SessionNotificationEngine.isIdlePrompt(
            notificationType: event?.notificationType, message: event?.message))

        // No leftover staging file.
        let tmpFiles = try FileManager.default
            .contentsOfDirectory(at: spool, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".tmp") }
        XCTAssertTrue(tmpFiles.isEmpty, "atomic rename must leave no .tmp file")
    }
}

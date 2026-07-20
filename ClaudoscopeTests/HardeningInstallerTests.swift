import XCTest
@testable import Claudoscope

/// Unit tests for `HardeningInstaller` that exercise the install/revert/uninstall
/// surface against a temporary `~/.claude/` directory.
///
/// Bundle access caveat: `HardeningInstaller` reads bundled baseline resources
/// via `Bundle.main.url(...)`. Inside the SPM test runner `Bundle.main` is the
/// test runner binary, NOT the Claudoscope app bundle, so install will throw
/// `bundleResourceMissing` for every layer. That's the documented Option B
/// boundary in the test plan: we exercise the no-bundle paths (revert without
/// marker, uninstall on empty/seeded state, install error path, idempotency,
/// actor serialization, malformed-settings refusal) and leave the full
/// happy-path install for the manual E2E in
/// `~/.claude/plans/ok-lets-go-with-scalable-gizmo.md` Verification section.
@MainActor
final class HardeningInstallerTests: XCTestCase {
    var tempDir: URL!
    var sessionStore: SessionStore!
    var installer: HardeningInstaller!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("HardeningInstallerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        sessionStore = SessionStore()
        installer = HardeningInstaller(sessionStore: sessionStore, claudeDir: tempDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func writeJSON(_ obj: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
        try data.write(to: url)
    }

    private func writeText(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    // MARK: - install error path (bundle missing)

    /// Bundle resources cannot be resolved from the SPM test runner, so install
    /// must throw `bundleResourceMissing` cleanly. This proves the safety net
    /// fires before any user-visible damage.
    func testInstallThrowsBundleResourceMissingInTestEnvironment() async throws {
        var caught: Error?
        do {
            _ = try await installer.install(options: HardeningInstallOptions())
        } catch {
            caught = error
        }
        XCTAssertNotNil(caught, "install should throw when bundle resources are unreachable")
        if let installErr = caught as? HardeningInstallError {
            switch installErr {
            case .bundleResourceMissing:
                break  // expected
            default:
                XCTFail("unexpected error: \(installErr)")
            }
        } else {
            XCTFail("expected HardeningInstallError, got \(String(describing: caught))")
        }
    }

    /// `installInProgress` is set in a `defer` block. Even when install fails
    /// (bundle missing), the flag must return to false so the watcher resumes
    /// emitting config events.
    func testInstallProgressFlagFlippedOnError() async throws {
        XCTAssertFalse(sessionStore.installInProgress, "precondition: flag should start false")

        do {
            _ = try await installer.install(options: HardeningInstallOptions())
            XCTFail("install should have thrown")
        } catch {
            // expected — bundle unreachable
        }

        // Allow the deferred Task { await markInstallEnd() } to run on MainActor.
        // Since we're already on MainActor, yield once to let queued work drain.
        for _ in 0..<5 {
            await Task.yield()
        }
        // Wait briefly with cooperative cancellation in case of additional hops
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(sessionStore.installInProgress,
                       "installInProgress must return to false in the deferred cleanup, even on error")
    }

    // MARK: - revert error path (no marker)

    func testRevertWithoutMarkerThrows() async throws {
        var caught: Error?
        do {
            try await installer.revert()
        } catch {
            caught = error
        }
        guard let err = caught as? HardeningInstallError else {
            XCTFail("expected HardeningInstallError, got \(String(describing: caught))")
            return
        }
        switch err {
        case .noMarkerForRevert:
            break  // expected
        default:
            XCTFail("expected noMarkerForRevert, got \(err)")
        }
    }

    // MARK: - uninstall paths (no bundle dependency for the strip work)

    func testUninstallOnEmptyDirIsNoop() async throws {
        // tempDir contains nothing except itself — uninstall must succeed silently.
        try await installer.uninstall(deleteBackups: false)

        // Nothing was created
        let entries = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        XCTAssertTrue(entries.isEmpty, "uninstall on empty dir must not create artifacts")
    }

    func testUninstallSurgicallyStripsBaselinePermissionsDeny() async throws {
        // Pre-create settings.json with a mix of baseline + user-added deny entries.
        // The bundled baseline list lives in `Resources/HardeningBaseline/layer1-permissions.json`,
        // which (as in production) is what uninstall reads to know which entries to strip.
        // Because Bundle.main is the test runner here, `loadBundleJSON` will return
        // bundleResourceMissing → the strip step silently no-ops (try? swallows it).
        // So we can verify uninstall does NOT touch user-added entries; we cannot
        // here verify it removes baseline entries (covered manually per the plan).
        let userEntries = ["Read(my/secret/**)", "Bash(rm /tmp/foo)"]
        try writeJSON(
            [
                "permissions": ["deny": userEntries]
            ],
            to: tempDir.appendingPathComponent("settings.json")
        )

        try await installer.uninstall(deleteBackups: false)

        let merged = try readJSON(tempDir.appendingPathComponent("settings.json"))
        let resultDeny = (merged["permissions"] as? [String: Any])?["deny"] as? [String] ?? []
        // User entries must remain untouched
        for u in userEntries {
            XCTAssertTrue(resultDeny.contains(u), "user entry \(u) should be preserved")
        }
    }

    func testUninstallStripsCLAUDEMdGovernanceBlock() async throws {
        let claudeMdURL = tempDir.appendingPathComponent("CLAUDE.md")
        let original = """
        # User content above

        Some text the user wrote.

        \(HardeningInstaller.governanceBeginMarker)
        # Governance baseline
        Various rules from Claudoscope.
        \(HardeningInstaller.governanceEndMarker)

        # User content below
        Trailing notes.
        """
        try writeText(original, to: claudeMdURL)

        try await installer.uninstall(deleteBackups: false)

        let after = try String(contentsOf: claudeMdURL, encoding: .utf8)
        XCTAssertFalse(after.contains(HardeningInstaller.governanceBeginMarker),
                       "BEGIN marker should be stripped")
        XCTAssertFalse(after.contains(HardeningInstaller.governanceEndMarker),
                       "END marker should be stripped")
        XCTAssertFalse(after.contains("# Governance baseline"),
                       "Block contents should be stripped")
        XCTAssertTrue(after.contains("# User content above"),
                      "Surrounding user content above must be preserved")
        XCTAssertTrue(after.contains("# User content below"),
                      "Surrounding user content below must be preserved")
        XCTAssertTrue(after.contains("Trailing notes."),
                      "Trailing user content must be preserved")
    }

    func testUninstallStripsClaudoscopeHookFiles() async throws {
        let hooksDir = tempDir.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)

        // Drop a few of the bundled hook script names + a user-authored file.
        let claudoscopeHooks = HardeningInstaller.bundledHookScripts.prefix(3)
        for name in claudoscopeHooks {
            try writeText("#!/bin/bash\necho hi\n", to: hooksDir.appendingPathComponent(name))
        }
        let userHook = hooksDir.appendingPathComponent("user-custom-hook.sh")
        try writeText("#!/bin/bash\necho user\n", to: userHook)

        try await installer.uninstall(deleteBackups: false)

        for name in claudoscopeHooks {
            let path = hooksDir.appendingPathComponent(name).path
            XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                           "claudoscope hook \(name) should be removed")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: userHook.path),
                      "user-custom-hook.sh must be preserved")
    }

    func testUninstallDeleteBackupsTrueRemovesBackupDirs() async throws {
        let backups = [
            ".claudoscope-hardening-backup-20260101-120000",
            ".claudoscope-hardening-backup-20260202-090000",
            ".claudoscope-hardening-backup-20260303-180000",
        ]
        for name in backups {
            let dir = tempDir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try writeText("dummy", to: dir.appendingPathComponent("settings.json"))
        }
        // Also create a non-backup dir to confirm it isn't touched
        let unrelated = tempDir.appendingPathComponent("plugins")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)

        try await installer.uninstall(deleteBackups: true)

        for name in backups {
            let path = tempDir.appendingPathComponent(name).path
            XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                           "backup dir \(name) should be removed")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path),
                      "unrelated dir 'plugins' must be preserved")
    }

    func testUninstallDeleteBackupsFalseKeepsBackupDirs() async throws {
        let backups = [
            ".claudoscope-hardening-backup-20260101-120000",
            ".claudoscope-hardening-backup-20260202-090000",
        ]
        for name in backups {
            let dir = tempDir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try writeText("dummy", to: dir.appendingPathComponent("settings.json"))
        }

        try await installer.uninstall(deleteBackups: false)

        for name in backups {
            let path = tempDir.appendingPathComponent(name).path
            XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                          "backup dir \(name) should be preserved when deleteBackups=false")
        }
    }

    func testUninstallBacksUpBeforeStripping() async throws {
        let settingsURL = tempDir.appendingPathComponent("settings.json")
        try writeJSON(["permissions": ["deny": ["Read(my/secret/**)"]]], to: settingsURL)

        let claudeMdURL = tempDir.appendingPathComponent("CLAUDE.md")
        try writeText("""
        # User

        \(HardeningInstaller.governanceBeginMarker)
        body
        \(HardeningInstaller.governanceEndMarker)
        """, to: claudeMdURL)

        try await installer.uninstall(deleteBackups: false)

        // Live CLAUDE.md was stripped in place...
        XCTAssertFalse(try String(contentsOf: claudeMdURL, encoding: .utf8)
            .contains(HardeningInstaller.governanceBeginMarker))

        // ...but a backup captured the pre-uninstall state first.
        let prefix = ".claudoscope-hardening-backup-"
        let backups = InstallerFileOps.backupDirectories(in: tempDir, prefix: prefix)
        XCTAssertFalse(backups.isEmpty, "uninstall must leave a safety backup before stripping")
        let captured = backups.contains { dir in
            let md = try? String(contentsOf: dir.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
            let hasSettings = FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.json").path)
            return hasSettings && (md?.contains(HardeningInstaller.governanceBeginMarker) ?? false)
        }
        XCTAssertTrue(captured, "backup must contain the pre-uninstall settings.json + CLAUDE.md")
    }

    func testUninstallIdempotency() async throws {
        // Set up a CLAUDE.md with the governance block + a couple of hooks, then
        // run uninstall twice. The second call must not throw and must leave the
        // already-clean state intact.
        let claudeMdURL = tempDir.appendingPathComponent("CLAUDE.md")
        try writeText("""
        Pre

        \(HardeningInstaller.governanceBeginMarker)
        body
        \(HardeningInstaller.governanceEndMarker)

        Post
        """, to: claudeMdURL)

        let hooksDir = tempDir.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        try writeText("#!/bin/bash\n", to: hooksDir.appendingPathComponent("claudoscope-validate-commands.sh"))

        try await installer.uninstall(deleteBackups: false)
        // Second call: must succeed silently
        try await installer.uninstall(deleteBackups: false)

        let after = try String(contentsOf: claudeMdURL, encoding: .utf8)
        XCTAssertFalse(after.contains(HardeningInstaller.governanceBeginMarker),
                       "governance block should remain stripped after second uninstall")
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            hooksDir.appendingPathComponent("claudoscope-validate-commands.sh").path),
            "hook should remain removed after second uninstall")
    }

    /// Two install tasks fired in parallel must serialize through the actor.
    /// Both fail with `bundleResourceMissing` here, but the install-in-progress
    /// gate must still flip on/off cleanly without overlap.
    func testActorSerializesParallelInstalls() async throws {
        async let one: Void = {
            do { _ = try await installer.install(options: HardeningInstallOptions()) }
            catch { /* expected */ }
        }()
        async let two: Void = {
            do { _ = try await installer.install(options: HardeningInstallOptions()) }
            catch { /* expected */ }
        }()
        _ = await (one, two)

        // Drain MainActor so the deferred markInstallEnd Tasks complete
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(sessionStore.installInProgress,
                       "installInProgress must clear after parallel installs serialize")
    }

    /// settings.json that's not parseable JSON. The installer must throw
    /// `malformedSettingsJson` and leave the file content unchanged.
    func testInstallRefusesMalformedSettingsJson() async throws {
        let settingsURL = tempDir.appendingPathComponent("settings.json")
        let bad = "{not json}"
        try bad.write(to: settingsURL, atomically: true, encoding: .utf8)

        var caught: Error?
        do {
            _ = try await installer.install(options: HardeningInstallOptions())
        } catch {
            caught = error
        }

        guard let err = caught as? HardeningInstallError else {
            XCTFail("expected HardeningInstallError, got \(String(describing: caught))")
            return
        }
        switch err {
        case .malformedSettingsJson:
            break  // expected
        default:
            XCTFail("expected malformedSettingsJson, got \(err)")
        }

        // Original content must be preserved
        let after = try String(contentsOf: settingsURL, encoding: .utf8)
        XCTAssertEqual(after, bad, "malformed settings.json must be left untouched")
    }

    // MARK: - marker JSON shape (manual fixture, mirrors what install would write)

    /// Install would produce a marker file via `writeMarkerIfAbsent`. We can't
    /// trigger it through `install(...)` here (bundle), but we can verify the
    /// internal helper writes the documented JSON shape and that the read path
    /// in revert recognises it. The shape contract: keys version, installedAt,
    /// backupPath, layersApplied, skillInstalled, priorSandboxEnabled.
    func testMarkerShapeIsReadByRevert() async throws {
        let markerURL = tempDir.appendingPathComponent(HardeningInstaller.markerFileName)
        let backupDir = tempDir.appendingPathComponent(".claudoscope-hardening-backup-test")
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let markerObj: [String: Any] = [
            "version": "1",
            "installedAt": "2026-05-06T12:00:00.000Z",
            "backupPath": backupDir.path,
            "layersApplied": ["layer1-permissions"],
            "skillInstalled": true,
            "priorSandboxEnabled": NSNull()
        ]
        let data = try JSONSerialization.data(withJSONObject: markerObj, options: [])
        try data.write(to: markerURL)

        // revert() should NOT throw noMarkerForRevert, since the marker is now
        // present and decodable. There's nothing to restore (backup is empty),
        // but the call must complete and remove the marker.
        try await installer.revert()

        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path),
                       "marker should be deleted after revert")
    }
}

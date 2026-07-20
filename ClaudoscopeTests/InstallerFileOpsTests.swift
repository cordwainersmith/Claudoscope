import XCTest
@testable import Claudoscope

/// Covers the shared backup primitive used by both the Hardening and Routing
/// installers. Guards the security-review fixes: owner-only backup dirs and
/// hard-failing (rather than silently swallowing) a backup copy failure.
final class InstallerFileOpsTests: XCTestCase {
    var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InstallerFileOpsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    private func writeText(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testCreateBackupSetsOwnerOnlyPermissions() throws {
        let src = tempDir.appendingPathComponent("settings.json")
        try writeText("{}", to: src)

        let backupDir = try InstallerFileOps.createBackup(
            claudeDir: tempDir,
            prefix: ".test-backup-",
            files: [(src, "settings.json")]
        )

        let attrs = try FileManager.default.attributesOfItem(atPath: backupDir.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.uint16Value, 0o700,
                       "backup dir must be owner-only (may hold secret-bearing settings.json)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupDir.appendingPathComponent("settings.json").path))
    }

    func testCreateBackupThrowsOnCopyFailure() throws {
        let src = tempDir.appendingPathComponent("settings.json")
        try writeText("{}", to: src)

        // Structural conflict: "a" is backed up as a file, then "a/b" needs "a" to be
        // a directory. The parent-dir create fails, which must now surface as an error
        // rather than being silently swallowed.
        XCTAssertThrowsError(
            try InstallerFileOps.createBackup(
                claudeDir: tempDir,
                prefix: ".test-backup-",
                files: [(src, "a"), (src, "a/b")]
            )
        ) { error in
            guard case InstallerFileOpsError.io = error else {
                return XCTFail("expected InstallerFileOpsError.io, got \(error)")
            }
        }
    }

    func testCreateBackupSkipsMissingSources() throws {
        let present = tempDir.appendingPathComponent("CLAUDE.md")
        try writeText("# hi", to: present)
        let missing = tempDir.appendingPathComponent("settings.json") // never created

        let backupDir = try InstallerFileOps.createBackup(
            claudeDir: tempDir,
            prefix: ".test-backup-",
            files: [(missing, "settings.json"), (present, "CLAUDE.md")]
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: backupDir.appendingPathComponent("CLAUDE.md").path),
                      "existing source must be backed up")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupDir.appendingPathComponent("settings.json").path),
                       "missing source must be skipped, not fabricated")
    }
}

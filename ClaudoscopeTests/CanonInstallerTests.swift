import XCTest
@testable import Claudoscope

final class CanonInstallerTests: XCTestCase {
    var tempDir: URL!
    var claudeDir: URL!
    var installer: CanonInstaller!

    let ruleText = "<!-- claudoscope-canon: v1 -->\n# Project Canon\nprotocol body\n"
    let seedText = "# Canon\n\nseed body\n"

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CanonInstallerTests-\(UUID().uuidString)")
        claudeDir = tempDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        installer = CanonInstaller()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    private var ruleURL: URL { claudeDir.appendingPathComponent("rules/canon.md") }
    private var dataURL: URL { claudeDir.appendingPathComponent("canon.md") }

    private func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    func testFreshInstallWritesProtocolAndSeedsData() async throws {
        let result = try await installer.install(into: claudeDir, ruleText: ruleText, seedText: seedText)
        XCTAssertEqual(read(ruleURL), ruleText)
        XCTAssertEqual(read(dataURL), seedText)
        XCTAssertTrue(result.seededDataFile)
        XCTAssertNil(result.backupPath)
    }

    func testInstallPreservesExistingRecords() async throws {
        // Simulate a repo that already has records (e.g. teammate committed them).
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let existingRecords = "# Canon\n\n## Existing\nkind: choice | date: 2026-07-01 | status: canon\nkeep me\n"
        try existingRecords.write(to: dataURL, atomically: true, encoding: .utf8)

        let result = try await installer.install(into: claudeDir, ruleText: ruleText, seedText: seedText)
        XCTAssertEqual(read(dataURL), existingRecords, "records file must never be clobbered")
        XCTAssertFalse(result.seededDataFile)
    }

    func testInstallBacksUpDifferingExistingRule() async throws {
        try FileManager.default.createDirectory(at: ruleURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "custom user protocol".write(to: ruleURL, atomically: true, encoding: .utf8)

        let result = try await installer.install(into: claudeDir, ruleText: ruleText, seedText: seedText)
        XCTAssertEqual(read(ruleURL), ruleText, "protocol is refreshed to the bundled version")
        XCTAssertNotNil(result.backupPath, "the pre-existing custom rule must be backed up")
        if let backup = result.backupPath {
            XCTAssertEqual(read(backup), "custom user protocol")
            try? FileManager.default.removeItem(at: backup.deletingLastPathComponent().deletingLastPathComponent())
        }
    }

    func testReinstallIdenticalRuleSkipsBackup() async throws {
        _ = try await installer.install(into: claudeDir, ruleText: ruleText, seedText: seedText)
        let result = try await installer.install(into: claudeDir, ruleText: ruleText, seedText: seedText)
        XCTAssertNil(result.backupPath, "identical rule content should not create a backup")
    }

    func testUninstallRemovesProtocolButKeepsRecords() async throws {
        _ = try await installer.install(into: claudeDir, ruleText: ruleText, seedText: seedText)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ruleURL.path))

        try await installer.uninstall(from: claudeDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ruleURL.path), "protocol rule removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataURL.path), "records file kept")
    }

    func testUninstallWithoutInstallIsNoOp() async throws {
        try await installer.uninstall(from: claudeDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ruleURL.path))
    }
}

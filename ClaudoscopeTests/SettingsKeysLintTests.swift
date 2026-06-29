import XCTest
@testable import Claudoscope

/// Tests for the settings.json lint rules added alongside new Claude Code keys:
/// CFG009 (sandbox.credentials), CFG010 (sandbox.allowAppleEvents),
/// CFG011 (respondToBashCommands), HRD013 (availableModels not enforced).
final class SettingsKeysLintTests: XCTestCase {
    var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SettingsKeysLintTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    private func writeSettings(_ obj: [String: Any]) throws {
        let url = tempDir.appendingPathComponent("settings.json")
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
        try data.write(to: url)
    }

    private func runConfig() async -> [LintResult] {
        await ConfigLinterService().lintConfig(globalClaudeDir: tempDir, projectRoot: nil)
    }

    private func runHardening() async -> [LintResult] {
        await ConfigLinterService().lintHardening(globalClaudeDir: tempDir, projectRoot: nil)
    }

    private func has(_ r: [LintResult], _ id: LintCheckId) -> Bool { r.contains { $0.checkId == id } }

    // MARK: - CFG009: sandbox.credentials

    func testCFG009FiresWhenSandboxEnabledWithoutCredentials() async throws {
        try writeSettings(["sandbox": ["enabled": true]])
        let r = await runConfig()
        XCTAssertTrue(has(r, .CFG009))
    }

    func testCFG009DoesNotFireWhenCredentialsConfigured() async throws {
        try writeSettings([
            "sandbox": ["enabled": true, "credentials": ["files": [["path": "~/.aws/credentials", "mode": "deny"]]]]
        ])
        let r = await runConfig()
        XCTAssertFalse(has(r, .CFG009))
    }

    func testCFG009DoesNotFireWhenSandboxDisabled() async throws {
        try writeSettings(["sandbox": ["enabled": false]])
        let r = await runConfig()
        XCTAssertFalse(has(r, .CFG009))
    }

    // MARK: - CFG010: sandbox.allowAppleEvents

    func testCFG010FiresWhenAppleEventsAllowed() async throws {
        try writeSettings(["sandbox": ["enabled": true, "allowAppleEvents": true]])
        let r = await runConfig()
        XCTAssertTrue(has(r, .CFG010))
    }

    func testCFG010DoesNotFireWhenAppleEventsDisabled() async throws {
        try writeSettings(["sandbox": ["enabled": true, "allowAppleEvents": false]])
        let r = await runConfig()
        XCTAssertFalse(has(r, .CFG010))
    }

    // MARK: - CFG011: respondToBashCommands

    func testCFG011FiresWhenRespondFalseWithHooks() async throws {
        try writeSettings(["respondToBashCommands": false, "hooks": ["Stop": []]])
        let r = await runConfig()
        XCTAssertTrue(has(r, .CFG011))
    }

    func testCFG011DoesNotFireWhenRespondFalseWithoutHooks() async throws {
        try writeSettings(["respondToBashCommands": false])
        let r = await runConfig()
        XCTAssertFalse(has(r, .CFG011))
    }

    func testCFG011DoesNotFireWhenRespondTrue() async throws {
        try writeSettings(["respondToBashCommands": true, "hooks": ["Stop": []]])
        let r = await runConfig()
        XCTAssertFalse(has(r, .CFG011))
    }

    // MARK: - HRD013: availableModels not enforced

    func testHRD013FiresWhenAvailableModelsNotEnforced() async throws {
        try writeSettings(["availableModels": ["claude-opus-4-8", "claude-sonnet-4-6"]])
        let r = await runHardening()
        XCTAssertTrue(has(r, .HRD013))
    }

    func testHRD013DoesNotFireWhenEnforced() async throws {
        try writeSettings(["availableModels": ["claude-opus-4-8"], "enforceAvailableModels": true])
        let r = await runHardening()
        XCTAssertFalse(has(r, .HRD013))
    }

    func testHRD013DoesNotFireWhenNoAvailableModels() async throws {
        try writeSettings(["enforceAvailableModels": false])
        let r = await runHardening()
        XCTAssertFalse(has(r, .HRD013))
    }
}

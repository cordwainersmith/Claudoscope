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

    // MARK: - CFG013: sandbox.filesystem.disabled (CC 2.1.216)

    func testCFG013FiresWhenFilesystemIsolationDisabled() async throws {
        try writeSettings(["sandbox": ["enabled": true, "filesystem": ["disabled": true]]])
        let r = await runConfig()
        XCTAssertTrue(has(r, .CFG013))
    }

    func testCFG013DoesNotFireWithFilesystemIsolationOn() async throws {
        try writeSettings(["sandbox": ["enabled": true, "filesystem": ["denyRead": ["~/.ssh/"]]]])
        let r = await runConfig()
        XCTAssertFalse(has(r, .CFG013))
    }

    // MARK: - CFG014: sandbox.network.strictAllowlist (CC 2.1.219)

    func testCFG014FiresWhenSandboxEnabledWithoutStrictAllowlist() async throws {
        try writeSettings(["sandbox": ["enabled": true, "network": ["allowedHosts": ["example.com"]]]])
        let r = await runConfig()
        XCTAssertTrue(has(r, .CFG014))
    }

    func testCFG014DoesNotFireWithStrictAllowlist() async throws {
        try writeSettings(["sandbox": ["enabled": true, "network": ["strictAllowlist": true]]])
        let r = await runConfig()
        XCTAssertFalse(has(r, .CFG014))
    }

    func testCFG014DoesNotFireWhenSandboxDisabled() async throws {
        try writeSettings(["sandbox": ["enabled": false]])
        let r = await runConfig()
        XCTAssertFalse(has(r, .CFG014))
    }

    // MARK: - CFG015: credential masking without TLS termination (CC 2.1.221/.224)

    func testCFG015FiresWhenMaskModeLacksTlsTerminate() async throws {
        try writeSettings([
            "sandbox": [
                "enabled": true,
                "credentials": ["envVars": [["name": "GITHUB_TOKEN", "mode": "mask"]]],
            ]
        ])
        let r = await runConfig()
        XCTAssertTrue(has(r, .CFG015))
    }

    func testCFG015DoesNotFireWithTlsTerminate() async throws {
        try writeSettings([
            "sandbox": [
                "enabled": true,
                "network": ["tlsTerminate": true],
                "credentials": ["envVars": [["name": "GITHUB_TOKEN", "mode": "mask"]]],
            ]
        ])
        let r = await runConfig()
        XCTAssertFalse(has(r, .CFG015))
    }

    func testCFG015DoesNotFireForDenyModeOnly() async throws {
        try writeSettings([
            "sandbox": [
                "enabled": true,
                "credentials": ["files": [["path": "~/.aws/credentials", "mode": "deny"]]],
            ]
        ])
        let r = await runConfig()
        XCTAssertFalse(has(r, .CFG015))
    }

    // MARK: - CFG018: crossSessionInbound under bypassPermissions (CC 2.1.224)

    func testCFG018FiresWhenAcceptingIntoBypassedSession() async throws {
        try writeSettings([
            "crossSessionInbound": "accept",
            "permissions": ["defaultMode": "bypassPermissions"],
        ])
        let r = await runConfig()
        XCTAssertTrue(has(r, .CFG018))
    }

    func testCFG018DoesNotFireWhenHolding() async throws {
        try writeSettings([
            "crossSessionInbound": "hold",
            "permissions": ["defaultMode": "bypassPermissions"],
        ])
        let r = await runConfig()
        XCTAssertFalse(has(r, .CFG018))
    }

    func testCFG018DoesNotFireWithoutBypass() async throws {
        try writeSettings(["crossSessionInbound": "accept"])
        let r = await runConfig()
        XCTAssertFalse(has(r, .CFG018))
    }

    // MARK: - Project-scoped keys Claude Code ignores

    /// Writes a project `.claude/settings.json` next to the global one and lints both.
    private func runConfigWithProject(_ obj: [String: Any], fileName: String = "settings.json") async throws -> [LintResult] {
        try writeSettings([:])
        let projectRoot = tempDir.appendingPathComponent("project")
        let claudeDir = projectRoot.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: obj)
        try data.write(to: claudeDir.appendingPathComponent(fileName))
        return await ConfigLinterService().lintConfig(globalClaudeDir: tempDir, projectRoot: projectRoot)
    }

    // CFG016: sandbox binary override in project scope (CC 2.1.232)

    func testCFG016FiresForProjectScopedRipgrepOverride() async throws {
        let r = try await runConfigWithProject(["sandbox": ["ripgrep": "/tmp/rg"]])
        XCTAssertTrue(has(r, .CFG016))
    }

    func testCFG016FiresInSettingsLocalToo() async throws {
        let r = try await runConfigWithProject(["sandbox": ["bwrapPath": "/tmp/bwrap"]], fileName: "settings.local.json")
        XCTAssertTrue(has(r, .CFG016))
    }

    func testCFG016DoesNotFireForOtherSandboxKeys() async throws {
        let r = try await runConfigWithProject(["sandbox": ["enabled": true]])
        XCTAssertFalse(has(r, .CFG016))
    }

    // CFG017: remoteControlAtStartup in project scope (CC 2.1.222)

    func testCFG017FiresForProjectScopedRemoteControl() async throws {
        let r = try await runConfigWithProject(["remoteControlAtStartup": true])
        XCTAssertTrue(has(r, .CFG017))
    }

    /// Repo-local scope can still turn Remote Control off, so `false` is honored.
    func testCFG017DoesNotFireWhenDisabling() async throws {
        let r = try await runConfigWithProject(["remoteControlAtStartup": false])
        XCTAssertFalse(has(r, .CFG017))
    }
}

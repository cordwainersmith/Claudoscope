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

    /// Points the managed-scope rules at a temp file so CFG019 never reads the
    /// real /Library policy (and never depends on whether one exists).
    private var managedURL: URL { tempDir.appendingPathComponent("managed-settings.json") }

    private func writeManagedSettings(_ obj: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
        try data.write(to: managedURL)
    }

    private func runConfig() async -> [LintResult] {
        await ConfigLinterService(managedSettingsURL: managedURL)
            .lintConfig(globalClaudeDir: tempDir, projectRoot: nil)
    }

    private func runHardening() async -> [LintResult] {
        await ConfigLinterService(managedSettingsURL: managedURL)
            .lintHardening(globalClaudeDir: tempDir, projectRoot: nil)
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
        return await ConfigLinterService(managedSettingsURL: managedURL)
            .lintConfig(globalClaudeDir: tempDir, projectRoot: projectRoot)
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

    // MARK: - CFG019: managedMcpServers stdio entry (CC 2.1.243)

    func testCFG019FiresForStdioManagedServer() async throws {
        try writeSettings([:])
        try writeManagedSettings([
            "managedMcpServers": ["inventory": ["command": "/usr/local/bin/inventory-mcp"]]
        ])
        let r = await runConfig()
        XCTAssertTrue(has(r, .CFG019))
    }

    func testCFG019DoesNotFireForHttpManagedServer() async throws {
        try writeSettings([:])
        try writeManagedSettings([
            "managedMcpServers": ["inventory": ["type": "http", "url": "https://mcp.example.com"]]
        ])
        let r = await runConfig()
        XCTAssertFalse(has(r, .CFG019))
    }

    /// A user-scope stdio server is normal; only the managed file is restricted.
    func testCFG019DoesNotFireForUserScopeStdioServer() async throws {
        try writeSettings(["mcpServers": ["inventory": ["command": "/usr/local/bin/inventory-mcp"]]])
        let r = await runConfig()
        XCTAssertFalse(has(r, .CFG019))
    }

    func testCFG019ReportsEachOffendingServerSeparately() async throws {
        try writeSettings([:])
        try writeManagedSettings([
            "managedMcpServers": [
                "inventory": ["command": "/usr/local/bin/inventory-mcp"],
                "audit": ["type": "stdio", "args": ["run"]]
            ]
        ])
        let r = await runConfig()
        XCTAssertEqual(r.filter { $0.checkId == .CFG019 }.count, 2)
    }

    // MARK: - CFG020: non-terminal wildcard in a Bash allow rule

    func testCFG020FiresForWildcardBeforeFinalSegment() async throws {
        try writeSettings(["permissions": ["allow": ["Bash(git * main)"]]])
        let r = await runConfig()
        XCTAssertTrue(has(r, .CFG020))
    }

    func testCFG020DoesNotFireForTerminalColonWildcard() async throws {
        try writeSettings(["permissions": ["allow": ["Bash(git push:*)"]]])
        let r = await runConfig()
        XCTAssertFalse(has(r, .CFG020))
    }

    func testCFG020DoesNotFireForTerminalSpaceWildcard() async throws {
        try writeSettings(["permissions": ["allow": ["Bash(npm run *)"]]])
        let r = await runConfig()
        XCTAssertFalse(has(r, .CFG020))
    }

    /// Only Bash rules match by prefix; a Read glob is not the same shape.
    func testCFG020DoesNotFireForNonBashTool() async throws {
        try writeSettings(["permissions": ["allow": ["Read(//path/*/secrets)"]]])
        let r = await runConfig()
        XCTAssertFalse(has(r, .CFG020))
    }

    /// deny rules are the safe direction; a broad wildcard there is intended.
    func testCFG020DoesNotFireForDenyRules() async throws {
        try writeSettings(["permissions": ["deny": ["Bash(curl * | sh)"]]])
        let r = await runConfig()
        XCTAssertFalse(has(r, .CFG020))
    }

    func testCFG020ReportsEachOffendingRuleSeparately() async throws {
        try writeSettings(["permissions": ["allow": ["Bash(git * main)", "Bash(docker * --rm)"]]])
        let r = await runConfig()
        XCTAssertEqual(r.filter { $0.checkId == .CFG020 }.count, 2)
    }

    /// The allow list usually lives in the repo, so project scope must be covered.
    func testCFG020FiresForProjectScopedAllowRule() async throws {
        let r = try await runConfigWithProject(["permissions": ["allow": ["Bash(git * main)"]]])
        XCTAssertTrue(has(r, .CFG020))
    }

    func testCFG020FiresInSettingsLocalToo() async throws {
        let r = try await runConfigWithProject(
            ["permissions": ["allow": ["Bash(docker * --rm)"]]],
            fileName: "settings.local.json"
        )
        XCTAssertTrue(has(r, .CFG020))
    }

    // MARK: - CFG021: output caps outside the clamp range (CC 2.1.253)

    func testCFG021FiresBelowRange() async throws {
        try writeSettings(["bashOutputMaxChars": 500])
        let r = await runConfig()
        XCTAssertTrue(has(r, .CFG021))
    }

    func testCFG021FiresAboveRange() async throws {
        try writeSettings(["taskOutputMaxChars": 500_000])
        let r = await runConfig()
        XCTAssertTrue(has(r, .CFG021))
    }

    func testCFG021DoesNotFireInsideRange() async throws {
        try writeSettings(["bashOutputMaxChars": 30_000, "taskOutputMaxChars": 128_000])
        let r = await runConfig()
        XCTAssertFalse(has(r, .CFG021))
    }

    func testCFG021DoesNotFireWhenUnset() async throws {
        try writeSettings([:])
        let r = await runConfig()
        XCTAssertFalse(has(r, .CFG021))
    }

    /// Both keys out of range must survive `LintResult.id` dedup.
    func testCFG021ReportsBothKeysSeparately() async throws {
        try writeSettings(["bashOutputMaxChars": 100, "taskOutputMaxChars": 900_000])
        let r = await runConfig()
        XCTAssertEqual(r.filter { $0.checkId == .CFG021 }.count, 2)
    }

    // MARK: - HRD014: blockReadsOutsideWorkingDirectories (CC 2.1.252)

    func testHRD014FiresWhenUnset() async throws {
        try writeSettings([:])
        let r = await runHardening()
        XCTAssertTrue(has(r, .HRD014))
    }

    func testHRD014FiresWhenExplicitlyFalse() async throws {
        try writeSettings(["permissions": ["blockReadsOutsideWorkingDirectories": false]])
        let r = await runHardening()
        XCTAssertTrue(has(r, .HRD014))
    }

    func testHRD014DoesNotFireWhenEnabled() async throws {
        try writeSettings(["permissions": ["blockReadsOutsideWorkingDirectories": true]])
        let r = await runHardening()
        XCTAssertFalse(has(r, .HRD014))
    }

    // MARK: - CFG022: boolean attribution (CC 2.1.281)

    func testCFG022FiresForBooleanAttributionInUserSettings() async throws {
        try writeSettings(["attribution": false])
        let r = await runConfig()
        XCTAssertTrue(has(r, .CFG022))
    }

    func testCFG022FiresForBooleanAttributionInProjectSettings() async throws {
        let r = try await runConfigWithProject(["attribution": false])
        XCTAssertEqual(r.filter { $0.checkId == .CFG022 }.map(\.displayPath), [".claude/settings.json"])
    }

    func testCFG022DoesNotFireForObjectForm() async throws {
        try writeSettings(["attribution": ["commit": "", "pr": ""]])
        let r = await runConfig()
        XCTAssertFalse(has(r, .CFG022))
    }

    // MARK: - CFG023: telemetry export in project scope (CC 2.1.282)

    func testCFG023FiresForProjectTelemetryEnable() async throws {
        let r = try await runConfigWithProject(["env": ["CLAUDE_CODE_ENABLE_TELEMETRY": "1"]])
        XCTAssertTrue(has(r, .CFG023))
    }

    func testCFG023FiresForExportersEndpointsAndContentCapture() async throws {
        for key in ["OTEL_METRICS_EXPORTER", "OTEL_LOGS_EXPORTER", "OTEL_TRACES_EXPORTER",
                    "OTEL_EXPORTER_OTLP_ENDPOINT", "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT", "OTEL_LOG_USER_PROMPTS"] {
            let r = try await runConfigWithProject(["env": [key: "otlp"]], fileName: "settings.local.json")
            XCTAssertTrue(has(r, .CFG023), key)
        }
    }

    func testCFG023DoesNotFireForTelemetryOffOrOtherOtelVars() async throws {
        let r = try await runConfigWithProject(["env": [
            "CLAUDE_CODE_ENABLE_TELEMETRY": "0",
            "OTEL_METRIC_EXPORT_INTERVAL": "60000",
            "OTEL_EXPORTER_OTLP_PROTOCOL": "grpc",
        ]])
        XCTAssertFalse(has(r, .CFG023))
    }

    func testCFG023DoesNotFireInUserSettings() async throws {
        try writeSettings(["env": ["CLAUDE_CODE_ENABLE_TELEMETRY": "1", "OTEL_METRICS_EXPORTER": "otlp"]])
        let r = await runConfig()
        XCTAssertFalse(has(r, .CFG023))
    }

    // MARK: - CFG024 / CFG025: MCP entries

    private func mcp(_ name: String, type: String? = nil) -> McpServerEntry {
        McpServerEntry(name: name, command: "node", args: [], url: nil, env: [:], level: "global", type: type)
    }

    private func lintMcp(_ servers: [McpServerEntry]) async -> [LintResult] {
        await ConfigLinterService(managedSettingsURL: managedURL).lintMcpServerEntries(servers)
    }

    func testCFG024FiresForReservedAnthropicSkillsName() async {
        let r = await lintMcp([mcp("anthropic-skills")])
        XCTAssertTrue(has(r, .CFG024))
    }

    func testCFG024DoesNotFireForClaudeAi() async {
        let r = await lintMcp([mcp("claude-ai"), mcp("github")])
        XCTAssertFalse(has(r, .CFG024))
    }

    func testCFG025FiresForSdkType() async {
        let r = await lintMcp([mcp("inproc", type: "sdk")])
        XCTAssertTrue(has(r, .CFG025))
    }

    func testCFG025DoesNotFireForStdioOrHttp() async {
        let r = await lintMcp([mcp("a", type: "stdio"), mcp("b", type: "http"), mcp("c")])
        XCTAssertFalse(has(r, .CFG025))
    }

    // MARK: - CFG026: managed-only model settings in user scope

    func testCFG026FiresPerManagedOnlyKey() async throws {
        try writeSettings(["deniedModels": ["claude-opus-4-1"], "availableModelsMatch": "opus", "allowedProviders": ["anthropic"]])
        let r = await runConfig()
        let findings = r.filter { $0.checkId == .CFG026 }
        XCTAssertEqual(findings.count, 3)
        XCTAssertEqual(Set(findings.map(\.id)).count, 3)
    }

    func testCFG026DoesNotFireWithoutThoseKeys() async throws {
        try writeSettings(["availableModels": ["opus"]])
        let r = await runConfig()
        XCTAssertFalse(has(r, .CFG026))
    }
}

import XCTest
@testable import Claudoscope

/// Lint rules for settings Claude Code changed in 2.1.323-2.1.325:
/// CFG032-CFG036.
final class CC2132xLintTests: XCTestCase {
    var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CC2132xLintTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    private var managedURL: URL { tempDir.appendingPathComponent("managed-settings.json") }
    private var linter: ConfigLinterService { ConfigLinterService(managedSettingsURL: managedURL) }

    private func writeJSON(_ obj: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
    }

    private func writeSettings(_ obj: [String: Any]) throws {
        try writeJSON(obj, to: tempDir.appendingPathComponent("settings.json"))
    }

    private var projectRoot: URL { tempDir.appendingPathComponent("project") }

    private func writeProjectSettings(_ obj: [String: Any], fileName: String = "settings.json") throws {
        try writeJSON(obj, to: projectRoot.appendingPathComponent(".claude").appendingPathComponent(fileName))
    }

    private func runConfig(project: Bool = false, now: Date = Date()) async -> [LintResult] {
        await linter.lintConfig(globalClaudeDir: tempDir, projectRoot: project ? projectRoot : nil, now: now)
    }

    private func results(_ r: [LintResult], _ id: LintCheckId) -> [LintResult] { r.filter { $0.checkId == id } }

    // MARK: - CFG032

    func testCFG032FiresWhenSandboxOnAndAutoAllowUnset() async throws {
        try writeSettings(["sandbox": ["enabled": true]])
        let r = results(await runConfig(), .CFG032)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.first?.displayPath, "settings.json")

        try writeSettings([:])
        try writeProjectSettings(["sandbox": ["enabled": true]], fileName: "settings.local.json")
        let p = results(await runConfig(project: true), .CFG032)
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p.first?.displayPath, ".claude/settings.local.json")
    }

    func testCFG032QuietWhenAutoAllowSetEitherWay() async throws {
        for value in [true, false] {
            try writeSettings(["sandbox": ["enabled": true, "autoAllowBashIfSandboxed": value]])
            do { let found = results(await runConfig(), .CFG032); XCTAssertTrue(found.isEmpty) }
        }

        try writeSettings(["sandbox": ["enabled": true]])
        try writeProjectSettings(["sandbox": ["autoAllowBashIfSandboxed": false]])
        do { let found = results(await runConfig(project: true), .CFG032); XCTAssertTrue(found.isEmpty) }

        try writeProjectSettings([:])
        try writeJSON(["sandbox": ["autoAllowBashIfSandboxed": true]], to: managedURL)
        do { let found = results(await runConfig(project: true), .CFG032); XCTAssertTrue(found.isEmpty) }
    }

    func testCFG032QuietWhenSandboxOff() async throws {
        try writeSettings(["sandbox": ["enabled": false]])
        do { let found = results(await runConfig(), .CFG032); XCTAssertTrue(found.isEmpty) }
        try writeSettings([:])
        do { let found = results(await runConfig(), .CFG032); XCTAssertTrue(found.isEmpty) }
    }

    // MARK: - CFG033

    func testCFG033FlagsWildcardInVariableValue() async throws {
        XCTAssertTrue(ConfigLinterService.bashRuleHasWildcardEnvValue("Bash(PORT=* npm run dev)"))
        XCTAssertTrue(ConfigLinterService.bashRuleHasWildcardEnvValue("Bash(A=1 B=x* make)"))

        try writeSettings(["permissions": ["allow": ["Bash(PORT=* npm run dev)"]]])
        let r = await runConfig()
        XCTAssertEqual(results(r, .CFG033).count, 1)
        XCTAssertTrue(results(r, .CFG020).isEmpty)

        try writeSettings([:])
        try writeProjectSettings(["permissions": ["allow": ["Bash(PORT=* npm run dev)"]]])
        do { let found = results(await runConfig(project: true), .CFG033); XCTAssertEqual(found.count, 1) }
    }

    func testCFG033QuietForOrdinaryBashRules() async throws {
        for rule in ["Bash(npm run *)", "Bash(PORT=3000 npm run dev)", "Bash(git push:*)", "Bash(echo a=*)", "Read(*)"] {
            XCTAssertFalse(ConfigLinterService.bashRuleHasWildcardEnvValue(rule), rule)
        }
        try writeSettings(["permissions": ["allow": ["Bash(npm run *)", "Bash(PORT=3000 npm run dev)"]]])
        do { let found = results(await runConfig(), .CFG033); XCTAssertTrue(found.isEmpty) }
    }

    // MARK: - CFG034

    func testCFG034FlagsRemovedKeys() async throws {
        try writeSettings(["subagentStatusLine": ["type": "command"], "pluginDigests": [String: Any]()])
        let r = results(await runConfig(), .CFG034)
        XCTAssertEqual(r.count, 1)
        let message = try XCTUnwrap(r.first?.message)
        XCTAssertTrue(message.contains("subagentStatusLine"))
        XCTAssertTrue(message.contains("pluginDigests"))

        try writeSettings([:])
        try writeProjectSettings(["pluginDigests": [String: Any]()])
        do { let found = results(await runConfig(project: true), .CFG034); XCTAssertEqual(found.count, 1) }
    }

    func testCFG034QuietOnCleanSettings() async throws {
        try writeSettings(["statusLine": ["type": "command", "command": "x"]])
        do { let found = results(await runConfig(), .CFG034); XCTAssertTrue(found.isEmpty) }
    }

    // MARK: - CFG035

    func testCFG035FiresForNonClaudeModelWithoutCap() async throws {
        try writeSettings(["model": "gpt-9-turbo"])
        do { let found = results(await runConfig(), .CFG035); XCTAssertEqual(found.count, 1) }

        try writeSettings(["env": ["ANTHROPIC_DEFAULT_SONNET_MODEL": "qwen3-coder"]])
        do { let found = results(await runConfig(), .CFG035); XCTAssertEqual(found.count, 1) }

        try writeSettings([:])
        try writeProjectSettings(["env": ["ANTHROPIC_MODEL": "glm-5"]])
        do { let found = results(await runConfig(project: true), .CFG035); XCTAssertEqual(found.count, 1) }
    }

    func testCFG035QuietWithEitherCapVariable() async throws {
        for cap in ["CLAUDE_CODE_DISABLE_1M_CONTEXT", "CLAUDE_CODE_MAX_CONTEXT_TOKENS"] {
            try writeSettings(["model": "gpt-9-turbo", "env": [cap: "1"]])
            do { let found = results(await runConfig(), .CFG035); XCTAssertTrue(found.isEmpty, cap) }
        }
    }

    func testCFG035QuietForClaudeModelsAndAliases() async throws {
        let models = ["claude-fable-5-2", "sonnet", "opus", "haiku", "opusplan", "default", "best",
                      "sonnet[1m]", "claude-opus-5-5[1m]"]
        for model in models {
            try writeSettings(["model": model])
            do { let found = results(await runConfig(), .CFG035); XCTAssertTrue(found.isEmpty, model) }
        }
    }

    // MARK: - CFG036

    func testCFG036FiresOnlyInProjectScope() async throws {
        try writeSettings(["env": ["CLAUDE_CODE_EXPERIMENTAL_CODE_MODE": "1"]])
        do { let found = results(await runConfig(), .CFG036); XCTAssertTrue(found.isEmpty) }

        try writeSettings([:])
        try writeProjectSettings(["env": ["CLAUDE_CODE_EXPERIMENTAL_CODE_MODE": "1"]])
        try writeProjectSettings(["env": ["CLAUDE_CODE_EXPERIMENTAL_CODE_MODE": "1"]], fileName: "settings.local.json")
        do { let found = results(await runConfig(project: true), .CFG036); XCTAssertEqual(found.count, 2) }
    }
}

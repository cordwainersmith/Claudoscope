import XCTest
@testable import Claudoscope

/// Lint rules for settings and definitions Claude Code changed in 2.1.290-2.1.318:
/// CFG027-CFG031, HRD015, HOOK006, SKL017.
final class CC2131xLintTests: XCTestCase {
    var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CC2131xLintTests-\(UUID().uuidString)")
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

    // MARK: - CFG027

    func testCFG027FiresForNestedUserNamespacesInUserOrProject() async throws {
        try writeSettings(["sandbox": ["allowNestedUserNamespaces": true]])
        do { let found = results(await runConfig(), .CFG027); XCTAssertEqual(found.count, 1) }

        try writeSettings([:])
        try writeProjectSettings(["sandbox": ["allowNestedUserNamespaces": true]])
        do { let found = results(await runConfig(project: true), .CFG027); XCTAssertEqual(found.count, 1) }
    }

    func testCFG027QuietWhenOff() async throws {
        try writeSettings(["sandbox": ["allowNestedUserNamespaces": false]])
        do { let found = results(await runConfig(), .CFG027); XCTAssertTrue(found.isEmpty) }
    }

    // MARK: - CFG028

    func testCFG028ListsUserScopeKeysSetInProject() async throws {
        try writeSettings([:])
        try writeProjectSettings([
            "claudeInChromeDefaultEnabled": true,
            "axScreenReader": true,
            "env": ["CLAUDE_CODE_DISABLE_ATTACHMENTS": "1", "OTHER": "x"],
        ], fileName: "settings.local.json")
        let r = results(await runConfig(project: true), .CFG028)
        XCTAssertEqual(r.count, 1)
        let message = try XCTUnwrap(r.first?.message)
        XCTAssertTrue(message.contains("claudeInChromeDefaultEnabled"))
        XCTAssertTrue(message.contains("axScreenReader"))
        XCTAssertTrue(message.contains("env.CLAUDE_CODE_DISABLE_ATTACHMENTS"))
        XCTAssertFalse(message.contains("OTHER"))
    }

    func testCFG028QuietInUserSettingsAndForChromeOff() async throws {
        try writeSettings(["axScreenReader": true, "claudeInChromeDefaultEnabled": true])
        try writeProjectSettings(["claudeInChromeDefaultEnabled": false])
        do { let found = results(await runConfig(project: true), .CFG028); XCTAssertTrue(found.isEmpty) }
    }

    // MARK: - CFG029

    func testCFG029FiresForFalsyDisableCompact() async throws {
        for value: Any in ["0", "false", "", 0] {
            try writeSettings(["env": ["DISABLE_COMPACT": value]])
            do { let found = results(await runConfig(), .CFG029); XCTAssertEqual(found.count, 1, "\(value)") }
        }
    }

    func testCFG029QuietWhenDisableCompactIsOn() async throws {
        try writeSettings(["env": ["DISABLE_COMPACT": "1"]])
        do { let found = results(await runConfig(), .CFG029); XCTAssertTrue(found.isEmpty) }
    }

    // MARK: - CFG030

    private func date(_ s: String) -> Date { ISO8601.parse(s)! }

    func testCFG030WarnsBeforeRemovalAndErrorsAfter() async throws {
        try writeSettings(["fastMode": true, "model": "claude-opus-4-8"])
        let before = results(await runConfig(now: date("2026-11-05T12:00:00.000Z")), .CFG030)
        XCTAssertEqual(before.first?.severity, .warning)
        let after = results(await runConfig(now: date("2026-12-01T12:00:00.000Z")), .CFG030)
        XCTAssertEqual(after.first?.severity, .error)
    }

    func testCFG030ReadsModelFromEnv() async throws {
        try writeSettings(["fastMode": true, "env": ["ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4-8[1m]"]])
        do { let found = results(await runConfig(), .CFG030); XCTAssertEqual(found.count, 1) }
    }

    func testCFG030QuietForOtherModelsOrFastOff() async throws {
        try writeSettings(["fastMode": true, "model": "claude-opus-5-5"])
        do { let found = results(await runConfig(), .CFG030); XCTAssertTrue(found.isEmpty) }
        try writeSettings(["fastMode": false, "model": "claude-opus-4-8"])
        do { let found = results(await runConfig(), .CFG030); XCTAssertTrue(found.isEmpty) }
    }

    // MARK: - CFG031

    func testStaleMcpPrefixRules() {
        let servers = ["jira__cloud", "jira_", "github"]
        let stale = ConfigLinterService.staleMcpPrefixRules(
            ["mcp__jira", "mcp__github", "mcp__jira__*", "mcp__github__create_issue", "Bash(ls)", "mcp__nothing"],
            servers: servers
        )
        XCTAssertEqual(stale.map(\.rule), ["mcp__jira", "mcp__jira__*"])
        XCTAssertEqual(stale.first?.servers, ["jira_", "jira__cloud"])
    }

    func testStaleRuleQuietWhenExactServerExists() {
        XCTAssertTrue(ConfigLinterService.staleMcpPrefixRules(["mcp__jira"], servers: ["jira", "jira_cloud"]).isEmpty)
    }

    func testCFG031ReadsEveryPermissionList() async throws {
        try writeSettings(["permissions": ["allow": ["mcp__jira"], "deny": ["mcp__slack"]]])
        let r = await linter.lintMcpPermissionRules(
            globalClaudeDir: tempDir, projectRoot: nil, mcpServerNames: ["jira__cloud", "slack_bot"]
        )
        XCTAssertEqual(results(r, .CFG031).count, 2)
        XCTAssertEqual(r.first?.fix, "mcp__jira__cloud__*")
    }

    // MARK: - HRD015

    func testHRD015FiresUnlessWritesAreConfined() async throws {
        try writeSettings([:])
        var r = await linter.lintHardening(globalClaudeDir: tempDir, projectRoot: nil)
        XCTAssertEqual(results(r, .HRD015).first?.severity, .info)
        try writeSettings(["permissions": ["blockWritesOutsideWorkingDirectories": true]])
        r = await linter.lintHardening(globalClaudeDir: tempDir, projectRoot: nil)
        XCTAssertTrue(results(r, .HRD015).isEmpty)
    }

    // MARK: - HOOK006

    private func hookGroup(_ event: String, _ hooks: [HookCommand], source: HookSource = .user) -> HookEventGroup {
        HookEventGroup(event: event, rules: [HookRule(id: UUID().uuidString, matcher: "Bash", hooks: hooks, source: source)])
    }

    func testHOOK006GroupsFailOpenGuardHooksPerSource() {
        let r = ConfigLinterService.failOpenGuardHooks([
            hookGroup("PreToolUse", [
                HookCommand(type: "command", command: "guard.sh", timeout: nil),
                HookCommand(type: "command", command: "strict.sh", timeout: nil, onFailure: "block"),
                HookCommand(type: "prompt", command: "", timeout: nil),
            ]),
            hookGroup("PermissionRequest", [HookCommand(type: "http", command: "", timeout: nil)]),
            hookGroup("PostToolUse", [HookCommand(type: "command", command: "log.sh", timeout: nil)]),
        ])
        XCTAssertEqual(r.count, 1)
        let message = r[0].message
        XCTAssertTrue(message.contains("guard.sh"))
        XCTAssertTrue(message.contains("PermissionRequest: http hook"))
        XCTAssertFalse(message.contains("strict.sh"))
        XCTAssertFalse(message.contains("log.sh"))
        XCTAssertTrue(message.hasPrefix("2 "))
    }

    func testHOOK006QuietWhenEveryGuardBlocks() {
        let r = ConfigLinterService.failOpenGuardHooks([
            hookGroup("PreToolUse", [HookCommand(type: "command", command: "guard.sh", timeout: nil, onFailure: "block")]),
        ])
        XCTAssertTrue(r.isEmpty)
    }

    // MARK: - SKL017

    func testUnsafeNameCharacters() {
        XCTAssertTrue(ConfigLinterService.hasUnsafeNameCharacters("deploy\u{202E}gnp", allowAngleBrackets: false))
        XCTAssertTrue(ConfigLinterService.hasUnsafeNameCharacters("zero\u{200B}width", allowAngleBrackets: true))
        XCTAssertTrue(ConfigLinterService.hasUnsafeNameCharacters("nb\u{00A0}space", allowAngleBrackets: true))
        XCTAssertTrue(ConfigLinterService.hasUnsafeNameCharacters("a<b", allowAngleBrackets: false))
        XCTAssertFalse(ConfigLinterService.hasUnsafeNameCharacters("a<b", allowAngleBrackets: true))
        XCTAssertFalse(ConfigLinterService.hasUnsafeNameCharacters("my-skill", allowAngleBrackets: false))
        XCTAssertFalse(ConfigLinterService.hasUnsafeNameCharacters("שלום", allowAngleBrackets: false))
    }

    func testSKL017FlagsSkillFolderAndCommandFile() async throws {
        let skillsDir = tempDir.appendingPathComponent("skills")
        let skillDir = skillsDir.appendingPathComponent("deploy\u{202E}gnp")
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try "---\nname: deploy\ndescription: Deploys.\n---\nBody".write(
            to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let (skillResults, _, _) = await linter.lintSkills(skillsDir: skillsDir)
        let finding = try XCTUnwrap(results(skillResults, .SKL017).first)
        XCTAssertTrue(finding.displayPath?.contains("<U+202E>") ?? false)

        let commandsDir = tempDir.appendingPathComponent("commands")
        try FileManager.default.createDirectory(at: commandsDir, withIntermediateDirectories: true)
        try "Run it".write(to: commandsDir.appendingPathComponent("ship\u{200B}.md"), atomically: true, encoding: .utf8)
        try "Run it".write(to: commandsDir.appendingPathComponent("ok.md"), atomically: true, encoding: .utf8)
        let commandResults = await linter.lintCommandToolRestrictions(globalClaudeDir: tempDir, projectRoot: nil)
        XCTAssertEqual(results(commandResults, .SKL017).count, 1)
    }
}

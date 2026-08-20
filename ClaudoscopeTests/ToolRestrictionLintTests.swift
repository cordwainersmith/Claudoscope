import XCTest
@testable import Claudoscope

/// Tests for #6: allowed-tools / disallowed-tools frontmatter linting
/// (SKL013 for skills, CMD007 for commands).
final class ToolRestrictionLintTests: XCTestCase {

    private func frontmatter(allowed: String?, disallowed: String?) -> String {
        var fm = "---\n"
        if let allowed { fm += "allowed-tools: \(allowed)\n" }
        if let disallowed { fm += "disallowed-tools: \(disallowed)\n" }
        fm += "---\nBody text.\n"
        return fm
    }

    // MARK: - SKL013 (skills)

    func testSkillValidToolsProduceNoFindings() async {
        let linter = ConfigLinterService()
        let results = await linter.lintSkillToolRestrictions(
            content: frontmatter(allowed: "Bash, Read", disallowed: "Write"),
            filePath: "/tmp/SKILL.md", displayPath: "demo"
        )
        XCTAssertTrue(results.isEmpty, "valid tool lists should not produce SKL013")
    }

    func testSkillContradictoryToolFiresError() async {
        let linter = ConfigLinterService()
        let results = await linter.lintSkillToolRestrictions(
            content: frontmatter(allowed: "Bash, Read", disallowed: "Bash"),
            filePath: "/tmp/SKILL.md", displayPath: "demo"
        )
        XCTAssertTrue(results.contains { $0.checkId == .SKL013 && $0.severity == .error },
                      "a tool in both allowed and disallowed should fire SKL013 as an error")
    }

    func testSkillUnknownToolFiresWarning() async {
        let linter = ConfigLinterService()
        let results = await linter.lintSkillToolRestrictions(
            content: frontmatter(allowed: "Bananas", disallowed: nil),
            filePath: "/tmp/SKILL.md", displayPath: "demo"
        )
        XCTAssertTrue(results.contains { $0.checkId == .SKL013 && $0.severity == .warning },
                      "an unknown tool name should fire SKL013 as a warning")
    }

    func testSkillMcpToolIsValid() async {
        let linter = ConfigLinterService()
        let results = await linter.lintSkillToolRestrictions(
            content: frontmatter(allowed: "mcp__server_tool, Read", disallowed: nil),
            filePath: "/tmp/SKILL.md", displayPath: "demo"
        )
        XCTAssertTrue(results.isEmpty, "mcp__* names should be accepted")
    }

    func testSkillNoFrontmatterProducesNoFindings() async {
        let linter = ConfigLinterService()
        let results = await linter.lintSkillToolRestrictions(
            content: "# Just a skill\n\nNo frontmatter here.",
            filePath: "/tmp/SKILL.md", displayPath: "demo"
        )
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - CMD007 (commands)

    func testCommandContradictoryToolFiresError() async {
        let linter = ConfigLinterService()
        let results = await linter.lintCommandFileToolRestrictions(
            content: frontmatter(allowed: "Edit", disallowed: "Edit"),
            filePath: "/tmp/cmd.md", displayPath: "cmd.md"
        )
        XCTAssertTrue(results.contains { $0.checkId == .CMD007 && $0.severity == .error })
    }

    func testCommandUnknownToolFiresWarning() async {
        let linter = ConfigLinterService()
        let results = await linter.lintCommandFileToolRestrictions(
            content: frontmatter(allowed: "Frobnicate", disallowed: nil),
            filePath: "/tmp/cmd.md", displayPath: "cmd.md"
        )
        XCTAssertTrue(results.contains { $0.checkId == .CMD007 && $0.severity == .warning })
    }

    func testCommandValidToolsProduceNoFindings() async {
        let linter = ConfigLinterService()
        let results = await linter.lintCommandFileToolRestrictions(
            content: frontmatter(allowed: "Bash, Glob, Grep", disallowed: nil),
            filePath: "/tmp/cmd.md", displayPath: "cmd.md"
        )
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - CMD007 reachable via the directory scanner (regression: orchestrator wiring)

    func testCommandScannerEmitsCMD007() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ToolRestrictionScan-\(UUID().uuidString)")
        let commandsDir = tmp.appendingPathComponent("commands")
        try FileManager.default.createDirectory(at: commandsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try frontmatter(allowed: "Bash", disallowed: "Bash")
            .write(to: commandsDir.appendingPathComponent("bad.md"), atomically: true, encoding: .utf8)

        let linter = ConfigLinterService()
        let results = await linter.lintCommandToolRestrictions(globalClaudeDir: tmp, projectRoot: nil)
        XCTAssertTrue(results.contains { $0.checkId == .CMD007 },
                      "the command-file scanner should surface CMD007 (and be wired into lint())")
    }

    // MARK: - knownTools currency

    /// The list stalled at 12 entries while Claude Code kept shipping tools, so every
    /// skill naming Agent, Skill, ToolSearch, or a Task* tool drew an SKL013 warning
    /// about working config.
    func testToolsShippedSinceTheOriginalListAreRecognized() async {
        let linter = ConfigLinterService()
        let recent = "Agent, Skill, ToolSearch, AskUserQuestion, SendMessage, ListAgents, "
            + "EnterPlanMode, ExitPlanMode, EnterWorktree, ExitWorktree, TaskOutput, TaskStop, "
            + "BashOutput, KillShell, SlashCommand, Workflow, Monitor"
        let results = await linter.lintSkillToolRestrictions(
            content: frontmatter(allowed: recent, disallowed: nil),
            filePath: "/tmp/SKILL.md", displayPath: "demo"
        )
        XCTAssertTrue(results.isEmpty, "unexpected findings: \(results.map(\.message))")
    }

    // MARK: - SKL014 (todo tools removed from current models)

    func testSkillLimitedToTodoToolsFiresSKL014() async {
        let linter = ConfigLinterService()
        let results = await linter.lintSkillToolRestrictions(
            content: frontmatter(allowed: "TodoWrite, TaskUpdate", disallowed: nil),
            filePath: "/tmp/SKILL.md", displayPath: "demo"
        )
        XCTAssertTrue(results.contains { $0.checkId == .SKL014 && $0.severity == .warning })
    }

    /// A skill that also allows real tools still works; it just loses the tracking.
    func testSkillAllowingTodoToolsAlongsideOthersDoesNotFire() async {
        let linter = ConfigLinterService()
        let results = await linter.lintSkillToolRestrictions(
            content: frontmatter(allowed: "Bash, Read, TodoWrite", disallowed: nil),
            filePath: "/tmp/SKILL.md", displayPath: "demo"
        )
        XCTAssertFalse(results.contains { $0.checkId == .SKL014 })
    }

    func testSkillWithNoAllowListDoesNotFireSKL014() async {
        let linter = ConfigLinterService()
        let results = await linter.lintSkillToolRestrictions(
            content: frontmatter(allowed: nil, disallowed: "TodoWrite"),
            filePath: "/tmp/SKILL.md", displayPath: "demo"
        )
        XCTAssertFalse(results.contains { $0.checkId == .SKL014 })
    }
}

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
}

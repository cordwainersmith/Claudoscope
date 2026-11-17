import XCTest
@testable import Claudoscope

/// SKL018: since Claude Code 2.1.325 scheduled tasks and /loop ask before
/// running a skill that declares allowed-tools or hooks.
final class UnattendedSkillLintTests: XCTestCase {
    var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("UnattendedSkillLintTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    private var linter: ConfigLinterService {
        ConfigLinterService(managedSettingsURL: tempDir.appendingPathComponent("managed-settings.json"))
    }

    private var skillsDir: URL { tempDir.appendingPathComponent("skills") }

    private func writeSkill(_ name: String, frontmatter: String) throws {
        let dir = skillsDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: Does \(name).\n\(frontmatter)---\nBody".write(
            to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    private func writeAllow(_ rules: [String]) throws {
        let data = try JSONSerialization.data(withJSONObject: ["permissions": ["allow": rules]])
        try data.write(to: tempDir.appendingPathComponent("settings.json"))
    }

    private func lint() async -> [LintResult] {
        await linter.lintUnattendedSkillApprovals(skillsDirs: [skillsDir], globalClaudeDir: tempDir, projectRoot: nil)
            .filter { $0.checkId == .SKL018 }
    }

    func testSKL018ListsSkillsWithAllowedToolsOrHooks() async throws {
        try writeSkill("restricted", frontmatter: "allowed-tools: Read, Grep\n")
        try writeSkill("hooked", frontmatter: "hooks:\n  Stop:\n    - command: echo\n")
        try writeSkill("plain", frontmatter: "")

        let results = await lint()
        let finding = try XCTUnwrap(results.first)
        XCTAssertEqual(finding.severity, .info)
        XCTAssertTrue(finding.message.contains("restricted"))
        XCTAssertTrue(finding.message.contains("hooked"))
        XCTAssertFalse(finding.message.contains("plain"))
    }

    func testSKL018QuietWhenSkillRuleCovers() async throws {
        try writeSkill("restricted", frontmatter: "allowed-tools: Read\n")
        try writeAllow(["Skill(restricted)"])
        let results = await lint()
        XCTAssertTrue(results.isEmpty)
    }

    func testSKL018QuietForBareSkillAllow() async throws {
        try writeSkill("restricted", frontmatter: "allowed-tools: Read\n")
        try writeAllow(["Skill"])
        let results = await lint()
        XCTAssertTrue(results.isEmpty)
    }

    func testSKL018EmitsOneAggregatedFinding() async throws {
        for i in 0..<12 {
            try writeSkill(String(format: "skill-%02d", i), frontmatter: "allowed-tools: Read\n")
        }
        let results = await lint()
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].message.contains("and 2 more"))
        XCTAssertFalse(results[0].message.contains("skill-11"))
    }

    func testSkillAllowRuleCovers() {
        XCTAssertTrue(ConfigLinterService.skillAllowRuleCovers(["Skill"], skill: "a"))
        XCTAssertTrue(ConfigLinterService.skillAllowRuleCovers(["Skill(*)"], skill: "a"))
        XCTAssertTrue(ConfigLinterService.skillAllowRuleCovers(["Bash", "Skill(a)"], skill: "a"))
        XCTAssertFalse(ConfigLinterService.skillAllowRuleCovers(["Skill(b)"], skill: "a"))
        XCTAssertFalse(ConfigLinterService.skillAllowRuleCovers(["Bash(*)"], skill: "a"))
        XCTAssertFalse(ConfigLinterService.skillAllowRuleCovers([], skill: "a"))
    }
}

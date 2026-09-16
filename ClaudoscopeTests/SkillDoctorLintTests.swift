import XCTest
@testable import Claudoscope

/// Tests for the skill-doctor rules: SKL010 (broken relative link),
/// SKL011 (tool restriction naming an unconfigured MCP server) and
/// SKL015 (the same skill name in two scopes).
final class SkillDoctorLintTests: XCTestCase {
    private var tempDir: URL!
    private var skillsDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SkillDoctorLintTests-\(UUID().uuidString)")
        skillsDir = tempDir.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    @discardableResult
    private func writeSkill(
        _ dirName: String,
        name: String? = nil,
        body: String,
        extraFiles: [String] = [],
        in root: URL? = nil
    ) throws -> URL {
        let parent = root ?? skillsDir!
        let dir = parent.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var content = "---\nname: \(name ?? dirName)\ndescription: A test skill.\n---\n"
        content += body
        try content.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        for file in extraFiles {
            let url = dir.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try "placeholder".write(to: url, atomically: true, encoding: .utf8)
        }
        return dir
    }

    private func lint(mcp: Set<String> = []) async -> [LintResult] {
        await ConfigLinterService()
            .lintSkills(skillsDir: skillsDir, scope: "user", mcpServerNames: mcp)
            .results
    }

    private func has(_ r: [LintResult], _ id: LintCheckId) -> Bool { r.contains { $0.checkId == id } }

    // MARK: - SKL010: relative links

    func testSKL010FiresForMissingRelativeFile() async throws {
        try writeSkill("demo", body: "See [the reference](references/palette.md).")
        let r = await lint()
        XCTAssertTrue(has(r, .SKL010))
    }

    func testSKL010DoesNotFireWhenTheFileExists() async throws {
        try writeSkill("demo",
                       body: "See [the reference](references/palette.md).",
                       extraFiles: ["references/palette.md"])
        let r = await lint()
        XCTAssertFalse(has(r, .SKL010))
    }

    func testSKL010ResolvesDotSlashAndAnchors() async throws {
        try writeSkill("demo",
                       body: "See [a](./notes.md) and [b](notes.md#section).",
                       extraFiles: ["notes.md"])
        let r = await lint()
        XCTAssertFalse(has(r, .SKL010))
    }

    func testSKL010IgnoresUrlsAnchorsAndAbsolutePaths() async throws {
        try writeSkill("demo", body: """
        [site](https://example.com/guide.md)
        [mail](mailto:nobody@example.com)
        [anchor](#usage)
        [abs](/etc/hosts)
        [home](~/.claude/settings.json)
        """)
        let r = await lint()
        XCTAssertFalse(has(r, .SKL010))
    }

    /// `[see](URL)` and `[x]({{path}})` are prose placeholders, not file paths.
    func testSKL010IgnoresPlaceholdersThatAreNotPaths() async throws {
        try writeSkill("demo", body: "[see](URL) and [x]({{path}}) and [y](<target>)")
        let r = await lint()
        XCTAssertFalse(has(r, .SKL010))
    }

    func testSKL010ReportsEachMissingPathOnce() async throws {
        try writeSkill("demo", body: """
        [a](docs/one.md), again [a](docs/one.md), and [b](docs/two.md)
        """)
        let r = await lint()
        XCTAssertEqual(r.filter { $0.checkId == .SKL010 }.count, 2)
    }

    // MARK: - SKL011: unconfigured MCP server in a tool restriction

    func testSKL011FiresForUnconfiguredServer() async throws {
        let dir = skillsDir.appendingPathComponent("demo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        ---
        name: demo
        description: A test skill.
        allowed-tools: mcp__ghost__query
        ---
        Body.
        """.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let r = await lint(mcp: ["atlassian"])
        XCTAssertTrue(has(r, .SKL011))
        XCTAssertFalse(has(r, .SKL013), "an mcp__ tool is not an unknown built-in")
    }

    func testSKL011DoesNotFireForConfiguredServer() async throws {
        let dir = skillsDir.appendingPathComponent("demo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        ---
        name: demo
        description: A test skill.
        allowed-tools: mcp__atlassian__jira_search, Read
        ---
        Body.
        """.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let r = await lint(mcp: ["atlassian"])
        XCTAssertFalse(has(r, .SKL011))
    }

    /// With no server inventory the check cannot distinguish "not configured"
    /// from "config unreadable", so it stays quiet.
    func testSKL011SilentWhenNoServersAreKnown() async throws {
        let dir = skillsDir.appendingPathComponent("demo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        ---
        name: demo
        description: A test skill.
        allowed-tools: mcp__ghost__query
        ---
        Body.
        """.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let r = await lint(mcp: [])
        XCTAssertFalse(has(r, .SKL011))
    }

    func testMcpServerSegmentParsing() {
        XCTAssertEqual(ConfigLinterService.mcpServerSegment(of: "mcp__atlassian__jira_search"), "atlassian")
        XCTAssertEqual(ConfigLinterService.mcpServerSegment(of: "mcp__brave-search"), "brave-search")
        XCTAssertNil(ConfigLinterService.mcpServerSegment(of: "Bash"))
        XCTAssertNil(ConfigLinterService.mcpServerSegment(of: "mcp__"))
    }

    // MARK: - SKL015: duplicate names across scopes

    func testSKL015FiresForTheSameNameInTwoScopes() async throws {
        let projectSkills = tempDir.appendingPathComponent("project-skills")
        try FileManager.default.createDirectory(at: projectSkills, withIntermediateDirectories: true)
        try writeSkill("shipper", name: "ship", body: "Body.")
        try writeSkill("ship", name: "ship", body: "Body.", in: projectSkills)

        let linter = ConfigLinterService()
        let user = await linter.lintSkills(skillsDir: skillsDir, scope: "user").identities
        let project = await linter.lintSkills(skillsDir: projectSkills, scope: "project").identities
        let r = await linter.lintDuplicateSkillNames(user + project)

        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.first?.checkId, .SKL015)
        XCTAssertTrue(r.first?.message.contains("project and user") == true, r.first?.message ?? "")
    }

    func testSKL015DoesNotFireForDistinctNames() async throws {
        let projectSkills = tempDir.appendingPathComponent("project-skills")
        try FileManager.default.createDirectory(at: projectSkills, withIntermediateDirectories: true)
        try writeSkill("ship", body: "Body.")
        try writeSkill("run", body: "Body.", in: projectSkills)

        let linter = ConfigLinterService()
        let user = await linter.lintSkills(skillsDir: skillsDir, scope: "user").identities
        let project = await linter.lintSkills(skillsDir: projectSkills, scope: "project").identities
        let dupes = await linter.lintDuplicateSkillNames(user + project)
        XCTAssertTrue(dupes.isEmpty)
    }

    /// A skill with no `name` falls back to its directory name, which is how
    /// Claude Code resolves it, so the collision must still be reported.
    func testSKL015UsesTheDirectoryNameWhenFrontmatterHasNone() async throws {
        let projectSkills = tempDir.appendingPathComponent("project-skills")
        try FileManager.default.createDirectory(at: projectSkills, withIntermediateDirectories: true)
        let dir = projectSkills.appendingPathComponent("ship")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\ndescription: No name field.\n---\nBody.\n"
            .write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try writeSkill("ship", body: "Body.")

        let linter = ConfigLinterService()
        let user = await linter.lintSkills(skillsDir: skillsDir, scope: "user").identities
        let project = await linter.lintSkills(skillsDir: projectSkills, scope: "project").identities
        let dupes = await linter.lintDuplicateSkillNames(user + project)
        XCTAssertTrue(dupes.contains { $0.checkId == .SKL015 })
    }


    // MARK: - SKL016: installed skill with no attributed turns

    private func skillEntry(_ name: String) -> SkillEntry {
        SkillEntry(name: name, displayName: name, description: "d",
                   metadata: [:], body: "", sizeBytes: 10)
    }

    private func rollup(_ ran: [(String, Int)]) -> AttributionRollup {
        AttributionRollup(
            skills: ran.map {
                SkillCostAggregate(skill: $0.0, sessionCount: 1, turnCount: $0.1,
                                   estimatedCost: 1, inputTokens: 1, outputTokens: 1,
                                   isInstalled: true)
            },
            mcps: [], agents: [], totalCost: 10
        )
    }

    func testSKL016FiresForAnInstalledSkillThatNeverRan() async {
        let r = await ConfigLinterService().lintUnusedSkills(
            skills: [skillEntry("ship"), skillEntry("dusty")],
            attribution: rollup([("ship", 300)])
        )
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.first?.checkId, .SKL016)
        XCTAssertTrue(r.first?.message.contains("dusty") == true)
    }

    /// Both tag forms fold to one key, so a plugin-qualified run counts.
    func testSKL016FoldsPluginQualifiedTags() async {
        let r = await ConfigLinterService().lintUnusedSkills(
            skills: [skillEntry("frontend-design")],
            attribution: rollup([("frontend-design:frontend-design", 300)])
        )
        XCTAssertTrue(r.isEmpty)
    }

    /// Under the volume floor, "never ran" just means the transcripts predate
    /// attribution tagging.
    func testSKL016SilentBelowTheAttributedTurnFloor() async {
        let r = await ConfigLinterService().lintUnusedSkills(
            skills: [skillEntry("dusty")],
            attribution: rollup([("ship", 5)])
        )
        XCTAssertTrue(r.isEmpty)
    }

    func testSKL016SilentWithNoAttributionAtAll() async {
        let r = await ConfigLinterService().lintUnusedSkills(
            skills: [skillEntry("dusty")],
            attribution: .empty
        )
        XCTAssertTrue(r.isEmpty)
    }
}

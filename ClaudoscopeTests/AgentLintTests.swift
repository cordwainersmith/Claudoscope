import XCTest
@testable import Claudoscope

/// AGT001-AGT003: subagent definition limits added in Claude Code 2.1.292-2.1.299.
final class AgentLintTests: XCTestCase {

    private func lint(_ frontmatter: String, servers: Set<String> = []) async -> [LintResult] {
        await ConfigLinterService().lintAgentDefinition(
            content: "---\n\(frontmatter)\n---\nYou are an agent.",
            filePath: "/tmp/agent.md",
            displayPath: ".claude/agents/agent.md",
            mcpServerNames: servers
        )
    }

    private func ids(_ r: [LintResult]) -> [LintCheckId] { r.map(\.checkId) }

    func testAGT001FlagsPrefixOnlyMcpToolEntry() async {
        let r = await lint("name: helper\ntools: Read, mcp__jira, mcp__github__*", servers: ["jira__cloud", "github"])
        XCTAssertEqual(ids(r), [.AGT001])
        XCTAssertEqual(r.first?.fix, "mcp__jira__cloud__*")
    }

    func testAGT001ReadsBlockList() async {
        let r = await lint("name: helper\ntools:\n  - Read\n  - mcp__jira", servers: ["jira_cloud"])
        XCTAssertEqual(ids(r), [.AGT001])
    }

    func testAGT002FlagsLongName() async {
        let r = await lint("name: \(String(repeating: "a", count: 257))")
        XCTAssertEqual(ids(r), [.AGT002])
        let ok = await lint("name: \(String(repeating: "a", count: 256))")
        XCTAssertTrue(ok.isEmpty)
    }

    func testAGT003FlagsMoreThan32Skills() async {
        let many = (1...33).map { "s\($0)" }.joined(separator: ", ")
        let r = await lint("name: helper\nskills: [\(many)]")
        XCTAssertEqual(ids(r), [.AGT003])
        let ok = await lint("name: helper\nskills: [\((1...32).map { "s\($0)" }.joined(separator: ", "))]")
        XCTAssertTrue(ok.isEmpty)
    }

    func testLintAgentsScansGlobalAndProjectDirs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentLintTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let global = root.appendingPathComponent("global")
        let project = root.appendingPathComponent("project")
        for dir in [global.appendingPathComponent("agents"), project.appendingPathComponent(".claude/agents")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "---\nname: \(String(repeating: "x", count: 300))\n---\nbody".write(
                to: dir.appendingPathComponent("long.md"), atomically: true, encoding: .utf8)
        }
        let r = await ConfigLinterService().lintAgents(projectRoot: project.path, globalDir: global, mcpServerNames: [])
        XCTAssertEqual(r.filter { $0.checkId == .AGT002 }.count, 2)
    }

    func testFrontmatterListShapes() {
        XCTAssertEqual(ConfigLinterService.frontmatterList("a, b"), ["a", "b"])
        XCTAssertEqual(ConfigLinterService.frontmatterList("[a, \"b\"]"), ["a", "b"])
        XCTAssertEqual(ConfigLinterService.frontmatterList("- a\n  - b"), ["a", "b"])
        XCTAssertEqual(ConfigLinterService.frontmatterList(nil), [])
    }
}

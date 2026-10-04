import XCTest
@testable import Claudoscope

/// AGENTS.md stands in for a missing project CLAUDE.md (root only).
final class AgentsMdDiscoveryTests: XCTestCase {
    private var tempRoot: URL!
    private var claudeDir: URL!
    private var projectRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .resolvingSymlinksInPath()
            .appendingPathComponent("agentsmd\(id)")
        claudeDir = tempRoot.appendingPathComponent("claude")
        projectRoot = tempRoot.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try await super.tearDown()
    }

    private func write(_ text: String, _ relative: String) throws {
        let url = projectRoot.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func discovered() async -> [String] {
        await ConfigLinterService()
            .discoverClaudeMdFiles(projectRoot: projectRoot.path, globalDir: claudeDir)
            .map { $0.path.replacingOccurrences(of: projectRoot.path + "/", with: "") }
    }

    private var projectId: String {
        projectRoot.path.replacingOccurrences(of: "/", with: "-")
    }

    func testAgentsMdAloneIsDiscovered() async throws {
        try write("# Agents", "AGENTS.md")
        let files = await discovered()
        XCTAssertEqual(files, ["AGENTS.md"])
    }

    func testClaudeMdWinsOverAgentsMd() async throws {
        try write("# Agents", "AGENTS.md")
        try write("# Claude", "CLAUDE.md")
        let files = await discovered()
        XCTAssertEqual(files, ["CLAUDE.md"])
    }

    func testDotClaudeClaudeMdAlsoSuppressesAgentsMd() async throws {
        try write("# Agents", "AGENTS.md")
        try write("# Claude", ".claude/CLAUDE.md")
        let files = await discovered()
        XCTAssertEqual(files, [".claude/CLAUDE.md"])
    }

    func testSubdirectoryAgentsMdIsNotDiscovered() async throws {
        try write("# Agents", "pkg/AGENTS.md")
        let files = await discovered()
        XCTAssertTrue(files.isEmpty)
    }

    func testMemoryProjectSlotFallsBackToAgentsMd() async throws {
        try write("# Agents", "AGENTS.md")
        let files = await ConfigService(claudeDir: claudeDir).loadMemoryFiles(projectId: projectId)
        let project = try XCTUnwrap(files.first { $0.id == "project" })
        XCTAssertEqual(project.label, "AGENTS.md")
        XCTAssertEqual(project.path, projectRoot.appendingPathComponent("AGENTS.md").path)
    }

    func testMemoryProjectSlotKeepsClaudeMdWhenPresent() async throws {
        try write("# Agents", "AGENTS.md")
        try write("# Claude", "CLAUDE.md")
        let files = await ConfigService(claudeDir: claudeDir).loadMemoryFiles(projectId: projectId)
        let project = try XCTUnwrap(files.first { $0.id == "project" })
        XCTAssertEqual(project.label, "CLAUDE.md")
    }
}

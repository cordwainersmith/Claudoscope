import XCTest
@testable import Claudoscope

/// Covers the pure `RoutingAgentEntry.load` builder that classifies each role
/// agent as installed / edited / bundled-only and parses its frontmatter.
final class RoutingAgentFilesTests: XCTestCase {
    var tempDir: URL!
    var agentsDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RoutingAgentFilesTests-\(UUID().uuidString)")
        agentsDir = tempDir.appendingPathComponent("agents")
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    private func makePayload() -> RoutingStackPayload {
        let recon = """
        ---
        name: recon
        description: Fast read-only lookup agent.
        model: haiku
        effort: low
        tools: Read, Glob, Grep
        ---

        You locate things and report facts.
        """
        var agentFiles: [RoutingStackPayload.AgentFile] = [
            .init(fileName: "recon.md", group: .core, content: recon)
        ]
        for name in RoutingStackPayloadLoader.coreAgentFileNames where name != "recon.md" {
            agentFiles.append(.init(fileName: name, group: .core, content: "core agent: \(name)\n"))
        }
        for name in RoutingStackPayloadLoader.securityAgentFileNames {
            agentFiles.append(.init(fileName: name, group: .security, content: "security agent: \(name)\n"))
        }
        return RoutingStackPayload(
            agentFiles: agentFiles,
            policyCoreFragment: "CORE",
            policySecurityFragment: "SECURITY",
            fallbackModel: ["opus", "sonnet"]
        )
    }

    private func write(_ text: String, _ fileName: String) throws {
        try text.write(to: agentsDir.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
    }

    func testInstalledUneditedParsesFrontmatter() throws {
        let payload = makePayload()
        // Write every agent's bundled content verbatim to disk.
        for file in payload.agentFiles {
            try write(file.content, file.fileName)
        }

        let entries = RoutingAgentEntry.load(payload: payload, agentsDir: agentsDir)
        let recon = try XCTUnwrap(entries.first { $0.fileName == "recon.md" })

        XCTAssertEqual(recon.source, .installed)
        XCTAssertEqual(recon.roleName, "recon")
        XCTAssertEqual(recon.model, "haiku")
        XCTAssertEqual(recon.effort, "low")
        XCTAssertEqual(recon.tools, ["Read", "Glob", "Grep"])
        XCTAssertEqual(recon.description, "Fast read-only lookup agent.")
        XCTAssertFalse(recon.body.isEmpty)
        XCTAssertFalse(recon.body.contains("---"), "frontmatter must be stripped from the rendered body")
        XCTAssertNotNil(recon.onDiskURL)
    }

    func testEditedWhenOnDiskDiffersFromBundle() throws {
        let payload = makePayload()
        try write("---\nname: recon\nmodel: haiku\n---\n\nHAND EDITED BODY", "recon.md")

        let entries = RoutingAgentEntry.load(payload: payload, agentsDir: agentsDir)
        let recon = try XCTUnwrap(entries.first { $0.fileName == "recon.md" })

        XCTAssertEqual(recon.source, .edited)
        XCTAssertTrue(recon.body.contains("HAND EDITED BODY"))
        XCTAssertNotNil(recon.onDiskURL)
    }

    func testBundledOnlyWhenNotInstalled() throws {
        let payload = makePayload()
        // agentsDir is empty — nothing installed.

        let entries = RoutingAgentEntry.load(payload: payload, agentsDir: agentsDir)
        XCTAssertEqual(entries.count, payload.agentFiles.count)

        let recon = try XCTUnwrap(entries.first { $0.fileName == "recon.md" })
        XCTAssertEqual(recon.source, .bundledOnly)
        XCTAssertNil(recon.onDiskURL)
        XCTAssertTrue(recon.body.contains("You locate things and report facts."))

        // Group split preserved.
        XCTAssertEqual(entries.filter { $0.group == .core }.count, RoutingStackPayloadLoader.coreAgentFileNames.count)
        XCTAssertEqual(entries.filter { $0.group == .security }.count, RoutingStackPayloadLoader.securityAgentFileNames.count)
    }
}

import XCTest
@testable import Claudoscope

/// Tests for file-only MCP auth status: derived from transport (stdio vs http)
/// and the ~/.claude/mcp-needs-auth-cache.json hint. No Keychain access.
final class McpAuthStatusTests: XCTestCase {
    private var tempRoot: URL!
    private var claudeDir: URL!
    private var service: ConfigService!
    private var managedURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-mcpauth-tests-\(UUID().uuidString)")
        claudeDir = tempRoot.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        managedURL = tempRoot.appendingPathComponent("managed-settings.json")
        service = ConfigService(claudeDir: claudeDir, managedSettingsURL: managedURL)
    }

    override func tearDown() async throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try await super.tearDown()
    }

    private func writeJSON(_ obj: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
        try data.write(to: url)
    }

    private func status(_ servers: [McpServerEntry], _ name: String) -> McpAuthStatus? {
        servers.first { $0.name == name }?.authStatus
    }

    func testAuthStatusFromCacheAndTransport() async throws {
        try writeJSON(["mcpServers": [
            "httpFlagged": ["url": "https://a.example"],
            "httpOk": ["url": "https://b.example"],
            "stdioOne": ["command": "node", "args": ["server.js"]]
        ]], to: claudeDir.appendingPathComponent("claude.json"))
        try writeJSON(["httpFlagged": ["timestamp": 1782718730674]],
                      to: claudeDir.appendingPathComponent("mcp-needs-auth-cache.json"))

        let servers = await service.loadMcpServers()
        XCTAssertEqual(status(servers, "httpFlagged"), .needsLogin)
        XCTAssertEqual(status(servers, "httpOk"), .authenticated)
        XCTAssertEqual(status(servers, "stdioOne"), .notApplicable)
    }

    func testHttpAuthenticatedWhenNoCache() async throws {
        try writeJSON(["mcpServers": ["h": ["url": "https://a.example"]]],
                      to: claudeDir.appendingPathComponent("claude.json"))
        let servers = await service.loadMcpServers()
        XCTAssertEqual(status(servers, "h"), .authenticated)
    }

    func testStdioAlwaysNotApplicable() async throws {
        try writeJSON(["mcpServers": ["s": ["command": "python"]]],
                      to: claudeDir.appendingPathComponent("claude.json"))
        // Even if the cache (wrongly) names a stdio server, transport wins.
        try writeJSON(["s": ["timestamp": 1]],
                      to: claudeDir.appendingPathComponent("mcp-needs-auth-cache.json"))
        let servers = await service.loadMcpServers()
        XCTAssertEqual(status(servers, "s"), .notApplicable)
    }

    // MARK: - managedMcpServers as a fourth source (CC 2.1.243)

    func testManagedServersAppearWithManagedLevel() async throws {
        try writeJSON(["managedMcpServers": [
            "corpDocs": ["type": "http", "url": "https://mcp.corp.example"]
        ]], to: managedURL)

        let servers = await service.loadMcpServers()
        let managed = servers.first { $0.name == "corpDocs" }
        XCTAssertNotNil(managed, "managed-settings.json servers must reach the MCPs rail")
        XCTAssertEqual(managed?.level, "managed")
        XCTAssertEqual(managed?.authStatus, .authenticated)
    }

    /// Org policy is not overridable, so the managed definition wins the name.
    func testManagedServerWinsOverUserScopeOnNameCollision() async throws {
        try writeJSON(["managedMcpServers": [
            "docs": ["type": "http", "url": "https://managed.example"]
        ]], to: managedURL)
        try writeJSON(["mcpServers": [
            "docs": ["command": "node", "args": ["local.js"]]
        ]], to: claudeDir.appendingPathComponent("claude.json"))

        let servers = await service.loadMcpServers()
        XCTAssertEqual(servers.filter { $0.name == "docs" }.count, 1)
        let docs = servers.first { $0.name == "docs" }
        XCTAssertEqual(docs?.level, "managed")
        XCTAssertEqual(docs?.url, "https://managed.example")
        XCTAssertNil(docs?.command)
    }

    func testUserScopeServersKeepGlobalLevelWhenManagedFileAbsent() async throws {
        try writeJSON(["mcpServers": ["docs": ["url": "https://a.example"]]],
                      to: claudeDir.appendingPathComponent("claude.json"))
        let servers = await service.loadMcpServers()
        XCTAssertEqual(servers.first { $0.name == "docs" }?.level, "global")
    }
}

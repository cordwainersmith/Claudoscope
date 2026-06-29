import XCTest
@testable import Claudoscope

/// Tests for file-only MCP auth status: derived from transport (stdio vs http)
/// and the ~/.claude/mcp-needs-auth-cache.json hint. No Keychain access.
final class McpAuthStatusTests: XCTestCase {
    private var tempRoot: URL!
    private var claudeDir: URL!
    private var service: ConfigService!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-mcpauth-tests-\(UUID().uuidString)")
        claudeDir = tempRoot.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        service = ConfigService(claudeDir: claudeDir)
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
}

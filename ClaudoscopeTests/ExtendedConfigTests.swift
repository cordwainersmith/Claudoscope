import XCTest
@testable import Claudoscope

final class ExtendedConfigTests: XCTestCase {
    private var tempRoot: URL!
    private var claudeDir: URL!
    private var service: ConfigService!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-extconfig-tests-\(UUID().uuidString)")
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

    private func writeSettings(_ obj: [String: Any]) throws {
        let url = claudeDir.appendingPathComponent("settings.json")
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
        try data.write(to: url)
    }

    // MARK: - prUrlTemplate (Claude Code 2.1.119)

    func testPrUrlTemplateRoundTrips() async throws {
        try writeSettings([
            "prUrlTemplate": "https://review.example.com/pr/{branch}"
        ])

        let ext = await service.loadExtendedConfig()
        XCTAssertEqual(ext.prUrlTemplate, "https://review.example.com/pr/{branch}")
    }

    func testPrUrlTemplateAbsentWhenUnset() async throws {
        try writeSettings([:])

        let ext = await service.loadExtendedConfig()
        XCTAssertNil(ext.prUrlTemplate)
    }

    func testPrUrlTemplateIsIndependentOfAttribution() async throws {
        // prUrlTemplate is a top-level key, not nested under attribution.
        // It should populate even when attribution is absent.
        try writeSettings([
            "prUrlTemplate": "https://gitlab.example.com/{pr}"
        ])

        let ext = await service.loadExtendedConfig()
        XCTAssertNil(ext.attribution)
        XCTAssertEqual(ext.prUrlTemplate, "https://gitlab.example.com/{pr}")
    }

    func testPrUrlTemplateCoexistsWithAttribution() async throws {
        try writeSettings([
            "attribution": [
                "commitMessage": "ci: {summary}",
                "pullRequestDescription": "## Summary\n{body}"
            ],
            "prUrlTemplate": "https://review.example.com/{pr}"
        ])

        let ext = await service.loadExtendedConfig()
        XCTAssertEqual(ext.attribution?.commitTemplate, "ci: {summary}")
        XCTAssertEqual(ext.attribution?.prTemplate, "## Summary\n{body}")
        XCTAssertEqual(ext.prUrlTemplate, "https://review.example.com/{pr}")
    }

    // MARK: - autoMode (CC 2.1.136)

    func testAutoModeAbsentWhenUnset() async throws {
        try writeSettings([:])
        let ext = await service.loadExtendedConfig()
        XCTAssertNil(ext.autoMode)
    }

    func testAutoModeHardDenyParsed() async throws {
        try writeSettings([
            "autoMode": [
                "hard_deny": ["Bash(rm *)", "WebFetch(*)"],
                "environment": []
            ]
        ])
        let ext = await service.loadExtendedConfig()
        XCTAssertNotNil(ext.autoMode)
        XCTAssertEqual(ext.autoMode?.hardDeny, ["Bash(rm *)", "WebFetch(*)"])
        XCTAssertEqual(ext.autoMode?.environment, [])
    }

    func testAutoModeEnvironmentParsed() async throws {
        try writeSettings([
            "autoMode": [
                "environment": ["$defaults", "github.com"],
                "hard_deny": []
            ]
        ])
        let ext = await service.loadExtendedConfig()
        XCTAssertNotNil(ext.autoMode)
        XCTAssertEqual(ext.autoMode?.environment, ["$defaults", "github.com"])
        XCTAssertEqual(ext.autoMode?.hardDeny, [])
    }

    func testAutoModeEmptyBlockYieldsEmptyArrays() async throws {
        try writeSettings([
            "autoMode": [String: Any]()
        ])
        let ext = await service.loadExtendedConfig()
        XCTAssertNotNil(ext.autoMode)
        XCTAssertEqual(ext.autoMode?.hardDeny, [])
        XCTAssertEqual(ext.autoMode?.environment, [])
    }

    // MARK: - allowAllClaudeAiMcps (CC 2.1.149)

    func testAllowAllClaudeAiMcpsAbsentWhenUnset() async throws {
        try writeSettings([:])
        let ext = await service.loadExtendedConfig()
        XCTAssertNil(ext.allowAllClaudeAiMcps)
    }

    func testAllowAllClaudeAiMcpsTrueWhenSet() async throws {
        try writeSettings(["allowAllClaudeAiMcps": true])
        let ext = await service.loadExtendedConfig()
        XCTAssertEqual(ext.allowAllClaudeAiMcps, true)
    }

    func testAllowAllClaudeAiMcpsFalseWhenSetFalse() async throws {
        try writeSettings(["allowAllClaudeAiMcps": false])
        let ext = await service.loadExtendedConfig()
        XCTAssertEqual(ext.allowAllClaudeAiMcps, false)
    }
}

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

    // MARK: - cleanupPeriodDays (transcript retention)

    func testCleanupPeriodDaysParsed() async throws {
        try writeSettings(["cleanupPeriodDays": 90])
        let ext = await service.loadExtendedConfig()
        XCTAssertEqual(ext.cleanupPeriodDays, 90)
    }

    func testCleanupPeriodDaysNilWhenUnset() async throws {
        try writeSettings([:])
        let ext = await service.loadExtendedConfig()
        XCTAssertNil(ext.cleanupPeriodDays)
    }

    // MARK: - sandbox.credentials / allowAppleEvents (CC 2.1.187 / 2.1.181)

    func testSandboxCredentialsObjectFormParsed() async throws {
        try writeSettings([
            "sandbox": [
                "credentials": [
                    "files": [["path": "~/.aws/credentials", "mode": "deny"]],
                    "envVars": [["name": "AWS_SECRET_ACCESS_KEY", "mode": "deny"]]
                ]
            ]
        ])
        let ext = await service.loadExtendedConfig()
        XCTAssertEqual(ext.sandbox?.credentials?.files, ["~/.aws/credentials"])
        XCTAssertEqual(ext.sandbox?.credentials?.envVars, ["AWS_SECRET_ACCESS_KEY"])
    }

    func testSandboxCredentialsStringArrayFormParsed() async throws {
        try writeSettings([
            "sandbox": ["credentials": ["files": ["~/.netrc"], "envVars": ["TOKEN"]]]
        ])
        let ext = await service.loadExtendedConfig()
        XCTAssertEqual(ext.sandbox?.credentials?.files, ["~/.netrc"])
        XCTAssertEqual(ext.sandbox?.credentials?.envVars, ["TOKEN"])
    }

    func testSandboxAllowAppleEventsParsed() async throws {
        try writeSettings(["sandbox": ["allowAppleEvents": true]])
        let ext = await service.loadExtendedConfig()
        XCTAssertEqual(ext.sandbox?.allowAppleEvents, true)
    }

    func testSandboxCredentialsAbsentByDefault() async throws {
        try writeSettings(["sandbox": ["enabled": true]])
        let ext = await service.loadExtendedConfig()
        XCTAssertNil(ext.sandbox?.credentials)
        XCTAssertEqual(ext.sandbox?.allowAppleEvents, false)
    }

    // MARK: - attribution.sessionUrl (CC 2.1.183)

    func testAttributionSessionUrlOmittedWhenFalse() async throws {
        try writeSettings(["attribution": ["sessionUrl": false]])
        let ext = await service.loadExtendedConfig()
        XCTAssertEqual(ext.attribution?.omitSessionUrl, true)
    }

    func testAttributionSessionUrlNotOmittedByDefault() async throws {
        try writeSettings(["attribution": ["commitMessage": "x"]])
        let ext = await service.loadExtendedConfig()
        XCTAssertEqual(ext.attribution?.omitSessionUrl, false)
    }

    // MARK: - autoMode.classifyAllShell (CC 2.1.193)

    func testAutoModeClassifyAllShellParsed() async throws {
        try writeSettings(["autoMode": ["classifyAllShell": true]])
        let ext = await service.loadExtendedConfig()
        XCTAssertEqual(ext.autoMode?.classifyAllShell, true)
    }

    // MARK: - availableModels / enforce / version pins / respondToBashCommands

    func testAvailableModelsAndEnforceParsed() async throws {
        try writeSettings([
            "availableModels": ["claude-opus-4-8", "claude-sonnet-4-6"],
            "enforceAvailableModels": true
        ])
        let ext = await service.loadExtendedConfig()
        XCTAssertEqual(ext.availableModels, ["claude-opus-4-8", "claude-sonnet-4-6"])
        XCTAssertTrue(ext.enforceAvailableModels)
    }

    func testRequiredVersionsParsed() async throws {
        try writeSettings([
            "requiredMinimumVersion": "2.1.180",
            "requiredMaximumVersion": "2.2.0"
        ])
        let ext = await service.loadExtendedConfig()
        XCTAssertEqual(ext.requiredMinimumVersion, "2.1.180")
        XCTAssertEqual(ext.requiredMaximumVersion, "2.2.0")
    }

    func testRespondToBashCommandsParsed() async throws {
        try writeSettings(["respondToBashCommands": false])
        let ext = await service.loadExtendedConfig()
        XCTAssertEqual(ext.respondToBashCommands, false)
    }

    func testNewKeysDefaultWhenUnset() async throws {
        try writeSettings([:])
        let ext = await service.loadExtendedConfig()
        XCTAssertNil(ext.respondToBashCommands)
        XCTAssertEqual(ext.availableModels, [])
        XCTAssertFalse(ext.enforceAvailableModels)
        XCTAssertNil(ext.requiredMinimumVersion)
        XCTAssertNil(ext.requiredMaximumVersion)
    }
}

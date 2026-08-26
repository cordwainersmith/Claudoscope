import XCTest
@testable import Claudoscope

/// Per-rule tests for the CHN lint family. `lintChannels(plugins:globalClaudeDir:)`
/// takes the plugin inventory directly plus a settings dir, so tests combine a
/// synthetic `[PluginInfo]` with a temp settings.json.
///
/// - CHN001: a known channel plugin (telegram/discord/imessage/fakechat) is
///   installed and enabled.
/// - CHN002: a channel plugin is enabled but settings.json env selects a
///   third-party provider (Vertex/Bedrock), where channels are silently ignored.
/// - CHN003: the channelsEnabled policy key is present in settings.json.
final class ChannelLintTests: XCTestCase {
    var tempDir: URL!
    private let linter = ConfigLinterService()

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ChannelLintTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func writeSettings(_ obj: [String: Any]) throws {
        let url = tempDir.appendingPathComponent("settings.json")
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
        try data.write(to: url)
    }

    private func plugin(
        _ name: String,
        marketplace: String = "mkt",
        enabled: Bool = true,
        components: [String]? = ["skills (1)"]
    ) -> PluginInfo {
        PluginInfo(
            fullName: "\(name)@\(marketplace)",
            name: name,
            marketplace: marketplace,
            enabled: enabled,
            components: components,
            dependencies: nil
        )
    }

    private func lint(_ plugins: [PluginInfo]) async -> [LintResult] {
        await linter.lintChannels(plugins: plugins, globalClaudeDir: tempDir)
    }

    private func has(_ r: [LintResult], _ id: LintCheckId) -> Bool { r.contains { $0.checkId == id } }

    private func count(_ r: [LintResult], _ id: LintCheckId) -> Int {
        r.filter { $0.checkId == id }.count
    }

    private func messages(_ r: [LintResult], _ id: LintCheckId) -> [String] {
        r.filter { $0.checkId == id }.map(\.message)
    }

    // MARK: - Empty inventory

    func testEmptyInventoryProducesNoResults() async {
        let results = await lint([])
        XCTAssertTrue(results.isEmpty, "No plugins and no settings file should produce no CHN results")
    }

    // MARK: - CHN001: channel plugin enabled

    func testCHN001FiresWhenChannelPluginEnabled() async {
        let results = await lint([plugin("telegram")])
        XCTAssertTrue(has(results, .CHN001))
        XCTAssertTrue(messages(results, .CHN001).first?.contains("\"telegram@mkt\"") ?? false,
                      "CHN001 message should quote the plugin fullName")
    }

    func testCHN001FiresOncePerChannelPlugin() async {
        let results = await lint([plugin("telegram"), plugin("discord")])
        XCTAssertEqual(count(results, .CHN001), 2)
    }

    func testCHN001DoesNotFireWhenChannelPluginDisabled() async {
        let results = await lint([plugin("telegram", enabled: false)])
        XCTAssertFalse(has(results, .CHN001))
    }

    func testCHN001DoesNotFireForNonChannelPluginName() async {
        let results = await lint([plugin("telegram-theme")])
        XCTAssertFalse(has(results, .CHN001), "Only exact channel plugin names should match")
    }

    func testCHN001FiresWithoutSettingsFile() async {
        // No settings.json written: the plugin inventory alone suffices.
        let results = await lint([plugin("imessage")])
        XCTAssertTrue(has(results, .CHN001))
    }

    // MARK: - CHN002: channels inert on third-party provider

    func testCHN002FiresWhenVertexEnvTruthy() async throws {
        try writeSettings(["env": ["CLAUDE_CODE_USE_VERTEX": "1"]])
        let results = await lint([plugin("telegram")])
        XCTAssertTrue(has(results, .CHN002))
        XCTAssertTrue(messages(results, .CHN002).first?.contains("CLAUDE_CODE_USE_VERTEX") ?? false,
                      "CHN002 message should name the provider signal key")
    }

    func testCHN002FiresWhenBedrockEnvTruthy() async throws {
        try writeSettings(["env": ["CLAUDE_CODE_USE_BEDROCK": "true"]])
        let results = await lint([plugin("discord")])
        XCTAssertTrue(has(results, .CHN002))
    }

    func testCHN002FiresWhenVertexProjectIdPresent() async throws {
        try writeSettings(["env": ["ANTHROPIC_VERTEX_PROJECT_ID": "my-project"]])
        let results = await lint([plugin("telegram")])
        XCTAssertTrue(has(results, .CHN002))
    }

    func testCHN002DoesNotFireWhenProviderEnvFalsy() async throws {
        try writeSettings(["env": [
            "CLAUDE_CODE_USE_VERTEX": "0",
            "CLAUDE_CODE_USE_BEDROCK": "false",
        ]])
        let results = await lint([plugin("telegram")])
        XCTAssertFalse(has(results, .CHN002))
    }

    func testCHN002DoesNotFireWithoutChannelPlugin() async throws {
        try writeSettings(["env": ["CLAUDE_CODE_USE_VERTEX": "1"]])
        let results = await lint([plugin("some-other-plugin")])
        XCTAssertFalse(has(results, .CHN002))
    }

    func testCHN002DoesNotFireWhenChannelPluginDisabled() async throws {
        try writeSettings(["env": ["CLAUDE_CODE_USE_VERTEX": "1"]])
        let results = await lint([plugin("telegram", enabled: false)])
        XCTAssertFalse(has(results, .CHN002))
    }

    // MARK: - CHN003: channelsEnabled policy key

    func testCHN003FiresWhenChannelsEnabledTrue() async throws {
        try writeSettings(["channelsEnabled": true])
        let results = await lint([])
        XCTAssertTrue(has(results, .CHN003))
        XCTAssertTrue(messages(results, .CHN003).first?.contains("true") ?? false)
    }

    func testCHN003FiresWhenChannelsEnabledFalse() async throws {
        try writeSettings(["channelsEnabled": false])
        let results = await lint([])
        XCTAssertTrue(has(results, .CHN003))
        XCTAssertTrue(messages(results, .CHN003).first?.contains("false") ?? false)
    }

    func testCHN003DoesNotFireWhenKeyAbsent() async throws {
        try writeSettings(["env": [:]])
        let results = await lint([])
        XCTAssertFalse(has(results, .CHN003))
    }

    func testCHN003DoesNotFireForAllowedChannelPluginsAlone() async throws {
        // allowedChannelPlugins is CFG004's key; CHN003 must stay disjoint.
        try writeSettings(["allowedChannelPlugins": ["telegram"]])
        let results = await lint([])
        XCTAssertFalse(has(results, .CHN003))
    }
}

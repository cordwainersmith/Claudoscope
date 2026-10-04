import XCTest
@testable import Claudoscope

/// Claude Mods (CC 2.1.287): plugins whose hooks.json lists TypeScript `modules`.
final class PluginModDetectionTests: XCTestCase {
    private var tempRoot: URL!
    private var claudeDir: URL!
    private var service: ConfigService!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-mod-tests-\(UUID().uuidString)")
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

    private func versionDir(_ plugin: String) -> URL {
        claudeDir.appendingPathComponent("plugins/cache/test-marketplace/\(plugin)/0.0.1")
    }

    private func writeJSON(_ obj: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
    }

    private func writeText(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private let registerSource = """
    export default function register(on) {
      on("session.start", () => {})
      on('tool.call', { matcher: "Bash" }, (e) => e)
      on( "turn.complete", () => {})
    }
    """

    func testHybridFileIsDetectedAsMod() async throws {
        let dir = versionDir("hybrid")
        try writeJSON([
            "modules": ["./register.ts"],
            "hooks": ["SessionStart": [["matcher": "", "hooks": [["type": "command", "command": "echo hi"]]]]],
        ], to: dir.appendingPathComponent("hooks/hooks.json"))
        try writeText(registerSource, to: dir.appendingPathComponent("hooks/register.ts"))

        let plugins = await service.loadPlugins()
        let plugin = try XCTUnwrap(plugins.first)
        XCTAssertTrue(plugin.isMod)
        XCTAssertEqual(plugin.modModules, ["./register.ts"])
        XCTAssertEqual(plugin.modHookEvents, ["session.start", "tool.call", "turn.complete"])
        XCTAssertEqual(plugin.components, ["hooks", "mod"])
    }

    func testModulesOnlyFileIsLabelledModNotHooks() async throws {
        let dir = versionDir("pure")
        try writeJSON(["modules": ["./register.ts"]], to: dir.appendingPathComponent("hooks/hooks.json"))
        try writeText(registerSource, to: dir.appendingPathComponent("hooks/register.ts"))

        let plugins = await service.loadPlugins()
        let plugin = try XCTUnwrap(plugins.first)
        XCTAssertTrue(plugin.isMod)
        XCTAssertEqual(plugin.components, ["mod"])
    }

    func testEventScanCoversNestedTsxAndSkipsTests() async throws {
        let dir = versionDir("nested")
        try writeJSON(["modules": ["./register.ts"]], to: dir.appendingPathComponent("hooks/hooks.json"))
        try writeText(registerSource, to: dir.appendingPathComponent("hooks/register.ts"))
        try writeText(#"on("ui.render", () => <Panel/>)"#, to: dir.appendingPathComponent("hooks/views/x.tsx"))
        try writeText(#"on("test.only", () => {})"#, to: dir.appendingPathComponent("hooks/tests/a.test.ts"))
        try writeText(#"on("spec.only", () => {})"#, to: dir.appendingPathComponent("hooks/b.test.ts"))

        let modInfo = await service.pluginModInfo(versionDir: dir)
        let info = try XCTUnwrap(modInfo)
        XCTAssertEqual(info.events, ["session.start", "tool.call", "turn.complete", "ui.render"])
    }

    func testClassicPluginIsNotAMod() async throws {
        let dir = versionDir("classic")
        try writeJSON([
            "hooks": ["Stop": [["matcher": "", "hooks": [["type": "command", "command": "echo bye"]]]]],
        ], to: dir.appendingPathComponent("hooks/hooks.json"))

        let plugins = await service.loadPlugins()
        let plugin = try XCTUnwrap(plugins.first)
        XCTAssertFalse(plugin.isMod)
        XCTAssertNil(plugin.modHookEvents)
        XCTAssertEqual(plugin.components, ["hooks"])
    }
}

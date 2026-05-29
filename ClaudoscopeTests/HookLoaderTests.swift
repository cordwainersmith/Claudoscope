import XCTest
@testable import Claudoscope

final class HookLoaderTests: XCTestCase {
    private var tempRoot: URL!
    private var claudeDir: URL!
    private var service: ConfigService!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-hooks-tests-\(UUID().uuidString)")
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

    // MARK: - Helpers

    private func writeJSON(_ obj: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
        try data.write(to: url)
    }

    private func makeRule(matcher: String, command: String) -> [String: Any] {
        [
            "matcher": matcher,
            "hooks": [["type": "command", "command": command]]
        ]
    }

    private func sourceLabels(_ groups: [HookEventGroup], event: String) -> [String] {
        guard let group = groups.first(where: { $0.event == event }) else { return [] }
        return group.rules.map { $0.source.label }
    }

    private func commandsFor(_ groups: [HookEventGroup], event: String) -> [String] {
        guard let group = groups.first(where: { $0.event == event }) else { return [] }
        return group.rules.flatMap { $0.hooks.map(\.command) }
    }

    // MARK: - User settings

    func testUserSourceOnly() async throws {
        try writeJSON([
            "hooks": [
                "Stop": [makeRule(matcher: "", command: "echo user-stop")]
            ]
        ], to: claudeDir.appendingPathComponent("settings.json"))

        let groups = await service.loadHooks(projectPaths: [])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(sourceLabels(groups, event: "Stop"), ["user"])
        XCTAssertEqual(commandsFor(groups, event: "Stop"), ["echo user-stop"])
    }

    // MARK: - Project + local settings

    func testProjectAndLocalSources() async throws {
        let projectRoot = tempRoot.appendingPathComponent("my-project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)

        try writeJSON([
            "hooks": [
                "PreToolUse": [makeRule(matcher: "Bash", command: "echo project-pre")]
            ]
        ], to: projectRoot.appendingPathComponent(".claude/settings.json"))

        try writeJSON([
            "hooks": [
                "PreToolUse": [makeRule(matcher: "Edit", command: "echo local-pre")]
            ]
        ], to: projectRoot.appendingPathComponent(".claude/settings.local.json"))

        let groups = await service.loadHooks(
            projectPaths: [(name: "my-project", path: projectRoot.path)]
        )

        let labels = sourceLabels(groups, event: "PreToolUse").sorted()
        XCTAssertEqual(labels, ["local: my-project", "project: my-project"])

        let commands = commandsFor(groups, event: "PreToolUse").sorted()
        XCTAssertEqual(commands, ["echo local-pre", "echo project-pre"])
    }

    // MARK: - Plugin layouts

    func testPluginLayoutCanonicalHooksJson() async throws {
        let versionDir = claudeDir
            .appendingPathComponent("plugins/cache/test-marketplace/canonical-plugin/0.0.1")

        try writeJSON([
            "PostToolUse": [makeRule(matcher: "Write", command: "echo canonical")]
        ], to: versionDir.appendingPathComponent("hooks/hooks.json"))

        let groups = await service.loadHooks(projectPaths: [])
        XCTAssertEqual(sourceLabels(groups, event: "PostToolUse"), ["plugin: canonical-plugin"])
        XCTAssertEqual(commandsFor(groups, event: "PostToolUse"), ["echo canonical"])
    }

    func testPluginLayoutInlineNestedManifest() async throws {
        let versionDir = claudeDir
            .appendingPathComponent("plugins/cache/test-marketplace/nested-plugin/0.0.1")

        try writeJSON([
            "name": "nested-plugin",
            "hooks": [
                "Notification": [makeRule(matcher: "", command: "echo nested")]
            ]
        ], to: versionDir.appendingPathComponent(".claude-plugin/plugin.json"))

        let groups = await service.loadHooks(projectPaths: [])
        XCTAssertEqual(sourceLabels(groups, event: "Notification"), ["plugin: nested-plugin"])
    }

    func testPluginLayoutFlatManifestWithStringPath() async throws {
        let versionDir = claudeDir
            .appendingPathComponent("plugins/cache/test-marketplace/flat-plugin/0.0.1")

        try writeJSON([
            "name": "flat-plugin",
            "hooks": "custom/path/hooks.json"
        ], to: versionDir.appendingPathComponent("plugin.json"))

        try writeJSON([
            "SessionStart": [makeRule(matcher: "", command: "echo flat")]
        ], to: versionDir.appendingPathComponent("custom/path/hooks.json"))

        let groups = await service.loadHooks(projectPaths: [])
        XCTAssertEqual(sourceLabels(groups, event: "SessionStart"), ["plugin: flat-plugin"])
        XCTAssertEqual(commandsFor(groups, event: "SessionStart"), ["echo flat"])
    }

    func testPluginLayoutCanonicalWinsOverManifest() async throws {
        // Both layouts present: hooks/hooks.json should win as the canonical form.
        let versionDir = claudeDir
            .appendingPathComponent("plugins/cache/test-marketplace/dual-plugin/0.0.1")

        try writeJSON([
            "PostToolUse": [makeRule(matcher: "Write", command: "echo canonical-wins")]
        ], to: versionDir.appendingPathComponent("hooks/hooks.json"))

        try writeJSON([
            "name": "dual-plugin",
            "hooks": [
                "PostToolUse": [makeRule(matcher: "Write", command: "echo manifest-loses")]
            ]
        ], to: versionDir.appendingPathComponent(".claude-plugin/plugin.json"))

        let groups = await service.loadHooks(projectPaths: [])
        XCTAssertEqual(commandsFor(groups, event: "PostToolUse"), ["echo canonical-wins"])
    }

    // MARK: - Mtime-based version selection (guards against the lex-sort bug)

    func testVersionSelectionPicksMostRecentlyModified() async throws {
        // Two version dirs where lex-sort would prefer "unknown" but mtime selects "0.0.1".
        let pluginDir = claudeDir
            .appendingPathComponent("plugins/cache/test-marketplace/mtime-plugin")

        let oldDir = pluginDir.appendingPathComponent("unknown")
        try writeJSON([
            "Stop": [makeRule(matcher: "", command: "echo old")]
        ], to: oldDir.appendingPathComponent("hooks/hooks.json"))

        let newDir = pluginDir.appendingPathComponent("0.0.1")
        try writeJSON([
            "Stop": [makeRule(matcher: "", command: "echo new")]
        ], to: newDir.appendingPathComponent("hooks/hooks.json"))

        // Force "0.0.1" to be more recent than "unknown".
        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: oldDir.path)
        try FileManager.default.setAttributes(
            [.modificationDate: now], ofItemAtPath: newDir.path)

        let groups = await service.loadHooks(projectPaths: [])
        XCTAssertEqual(commandsFor(groups, event: "Stop"), ["echo new"])
    }

    // MARK: - Cross-source merging

    func testConcatenationAcrossAllSources() async throws {
        // User
        try writeJSON([
            "hooks": ["Stop": [makeRule(matcher: "", command: "echo user")]]
        ], to: claudeDir.appendingPathComponent("settings.json"))

        // Project
        let projectRoot = tempRoot.appendingPathComponent("proj")
        try writeJSON([
            "hooks": ["Stop": [makeRule(matcher: "", command: "echo project")]]
        ], to: projectRoot.appendingPathComponent(".claude/settings.json"))

        // Plugin
        let versionDir = claudeDir
            .appendingPathComponent("plugins/cache/mp/p/0.0.1")
        try writeJSON([
            "Stop": [makeRule(matcher: "", command: "echo plugin")]
        ], to: versionDir.appendingPathComponent("hooks/hooks.json"))

        let groups = await service.loadHooks(
            projectPaths: [(name: "proj", path: projectRoot.path)]
        )

        let commands = commandsFor(groups, event: "Stop").sorted()
        XCTAssertEqual(commands, ["echo plugin", "echo project", "echo user"])

        let sources = sourceLabels(groups, event: "Stop").sorted()
        XCTAssertEqual(sources, ["plugin: p", "project: proj", "user"])
    }

    // MARK: - Unknown event names surface (no hardcoded whitelist)

    func testUnknownEventNamesAreSurfaced() async throws {
        try writeJSON([
            "hooks": [
                "FileChanged": [makeRule(matcher: "", command: "echo file-changed")],
                "PreCompact": [makeRule(matcher: "", command: "echo pre-compact")]
            ]
        ], to: claudeDir.appendingPathComponent("settings.json"))

        let groups = await service.loadHooks(projectPaths: [])
        let events = groups.map(\.event).sorted()
        XCTAssertEqual(events, ["FileChanged", "PreCompact"])
    }

    // MARK: - Empty / missing inputs

    func testNoSourcesReturnsEmpty() async throws {
        let groups = await service.loadHooks(projectPaths: [])
        XCTAssertTrue(groups.isEmpty)
    }

    // MARK: - Claude Code 2.1.141 terminalSequence + 2.1.152 MessageDisplay

    func testMessageDisplayEventSurfaces() async throws {
        try writeJSON([
            "hooks": [
                "MessageDisplay": [makeRule(matcher: "", command: "echo msg-display")]
            ]
        ], to: claudeDir.appendingPathComponent("settings.json"))

        let groups = await service.loadHooks(projectPaths: [])
        let events = groups.map(\.event)
        XCTAssertTrue(events.contains("MessageDisplay"), "MessageDisplay event should surface without a hardcoded whitelist")
        XCTAssertEqual(commandsFor(groups, event: "MessageDisplay"), ["echo msg-display"])
    }

    func testTerminalSequenceFieldIsExtractedFromJSON() async throws {
        // ConfigService extracts terminalSequence from the hook dict and stores it on
        // HookCommand.terminalSequence (CC 2.1.141).
        try writeJSON([
            "hooks": [
                "MessageDisplay": [[
                    "matcher": "",
                    "hooks": [[
                        "type": "command",
                        "command": "echo seq-hook",
                        "terminalSequence": "\\033[1mHELLO\\033[0m"
                    ]]
                ]]
            ]
        ], to: claudeDir.appendingPathComponent("settings.json"))

        let groups = await service.loadHooks(projectPaths: [])
        guard let group = groups.first(where: { $0.event == "MessageDisplay" }) else {
            return XCTFail("MessageDisplay group not found")
        }
        let hook = try XCTUnwrap(group.rules.first?.hooks.first, "Expected at least one hook command")
        XCTAssertEqual(hook.command, "echo seq-hook")
        XCTAssertEqual(hook.terminalSequence, "\\033[1mHELLO\\033[0m")
    }
}

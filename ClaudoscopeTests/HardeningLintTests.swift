import XCTest
@testable import Claudoscope

/// Per-rule tests for the HRD lint family. Each test seeds a synthetic
/// `~/.claude/`-style temp directory and asserts which HRD checks fire.
///
/// HRD006 and the drift sub-case of HRD010/HRD011 require bundle-resource
/// access (`Bundle.main.url(...)`). In the SPM test runner `Bundle.main` is
/// the test runner binary, not the Claudoscope app bundle, so the linter's
/// sidecar lookups return nil and those drift checks silently skip — which
/// is the documented fallback. Tests below verify the SKIP behavior.
final class HardeningLintTests: XCTestCase {
    var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("HardeningLintTests-\(UUID().uuidString)")
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

    @discardableResult
    private func writeHookFile(name: String, executable: Bool, body: String = "#!/bin/bash\necho ok\n", worldWritable: Bool = false) throws -> URL {
        let hooksDir = tempDir.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        let url = hooksDir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        var perms: UInt16 = executable ? 0o755 : 0o644
        if worldWritable { perms |= 0o002 }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: perms)],
            ofItemAtPath: url.path
        )
        return url
    }

    private func writeCLAUDEMd(_ body: String) throws {
        let url = tempDir.appendingPathComponent("CLAUDE.md")
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    private func runLint() async -> [LintResult] {
        let linter = ConfigLinterService()
        return await linter.lintHardening(globalClaudeDir: tempDir, projectRoot: nil)
    }

    private func contains(_ results: [LintResult], _ id: LintCheckId) -> Bool {
        results.contains { $0.checkId == id }
    }

    private func count(_ results: [LintResult], _ id: LintCheckId) -> Int {
        results.filter { $0.checkId == id }.count
    }

    /// Build a settings.json that fully satisfies the HRD baseline so individual
    /// tests can knock out one piece at a time without other rules drowning out
    /// the assertion. Hook commands point at files we'll create in the temp dir.
    private func writeFullySatisfyingSettings(extra: [String: Any] = [:]) throws {
        let hooksDir = tempDir.appendingPathComponent("hooks").path
        var hookEntries: [[String: Any]] = []
        for basename in ConfigLinterService.hardeningExpectedHookBasenames {
            hookEntries.append([
                "matcher": "Bash",
                "hooks": [
                    ["type": "command", "command": "\(hooksDir)/\(basename)"]
                ]
            ])
        }

        var obj: [String: Any] = [
            "sandbox": [
                "enabled": true,
                "filesystem": ["denyRead": [], "denyWrite": []],
                "network": ["allowedHosts": []]
            ],
            "permissions": [
                "deny": ConfigLinterService.hardeningDenyBaseline
            ],
            "hooks": [
                "PreToolUse": hookEntries
            ],
            "autoMode": [
                "environment": ["$defaults"]
            ]
        ]
        for (k, v) in extra { obj[k] = v }
        try writeSettings(obj)

        // Create the hook script files referenced above so HRD004 doesn't fire
        for basename in ConfigLinterService.hardeningExpectedHookBasenames {
            try writeHookFile(name: basename, executable: true)
        }

        // Governance markers in CLAUDE.md so HRD010 doesn't fire (drift sub-
        // case is bundle-dependent and silently skipped without bundle access)
        let governance = """
        Some prior content.

        \(ConfigLinterService.hardeningGovernanceBeginMarker)
        # Governance
        Body.
        \(ConfigLinterService.hardeningGovernanceEndMarker)
        """
        try writeCLAUDEMd(governance)
    }

    // MARK: - HRD001: sandbox.enabled

    func testHRD001FiresWhenSandboxDisabled() async throws {
        try writeSettings(["sandbox": ["enabled": false]])
        let results = await runLint()
        XCTAssertTrue(contains(results, .HRD001),
                      "HRD001 should fire when sandbox.enabled is false")
    }

    func testHRD001FiresWhenSandboxKeyMissing() async throws {
        try writeSettings(["permissions": ["deny": []]])
        let results = await runLint()
        XCTAssertTrue(contains(results, .HRD001),
                      "HRD001 should fire when sandbox key is missing")
    }

    func testHRD001PassesWhenSandboxEnabled() async throws {
        try writeFullySatisfyingSettings()
        let results = await runLint()
        XCTAssertFalse(contains(results, .HRD001),
                       "HRD001 should not fire when sandbox.enabled is true")
    }

    // MARK: - HRD002: permissions.deny baseline coverage

    func testHRD002FiresPerMissingDenyEntry() async throws {
        // Provide an empty deny list. Every baseline entry should fire its own
        // HRD002 result (count must equal baseline list size).
        try writeSettings([
            "sandbox": ["enabled": true],
            "permissions": ["deny": [String]()]
        ])
        let results = await runLint()
        let firedCount = count(results, .HRD002)
        XCTAssertEqual(firedCount, ConfigLinterService.hardeningDenyBaseline.count,
                       "HRD002 should fire once per missing baseline deny entry")
    }

    func testHRD002DoesNotFireWhenAllBaselineDenyEntriesPresent() async throws {
        try writeFullySatisfyingSettings()
        let results = await runLint()
        XCTAssertFalse(contains(results, .HRD002),
                       "HRD002 should not fire when full baseline deny list is present")
    }

    // MARK: - HRD003: expected hardening hook not registered

    func testHRD003FiresWhenExpectedHookNotRegistered() async throws {
        // settings.json with no hooks dict at all
        try writeSettings([
            "sandbox": ["enabled": true],
            "permissions": ["deny": ConfigLinterService.hardeningDenyBaseline]
        ])
        let results = await runLint()
        let firedCount = count(results, .HRD003)
        XCTAssertEqual(firedCount, ConfigLinterService.hardeningExpectedHookBasenames.count,
                       "HRD003 should fire once per expected hook missing from registration")
    }

    // MARK: - HRD004: registered hook file missing on disk

    func testHRD004FiresWhenRegisteredHookFileMissing() async throws {
        let hooksDir = tempDir.appendingPathComponent("hooks").path
        let missingScriptPath = "\(hooksDir)/claudoscope-validate-commands.sh"
        try writeSettings([
            "sandbox": ["enabled": true],
            "permissions": ["deny": ConfigLinterService.hardeningDenyBaseline],
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": "Bash",
                        "hooks": [
                            ["type": "command", "command": missingScriptPath]
                        ]
                    ]
                ]
            ]
        ])
        // Deliberately do NOT create the file at missingScriptPath.

        let results = await runLint()
        XCTAssertTrue(contains(results, .HRD004),
                      "HRD004 should fire when a registered hook command file is absent")
        // Sanity: the message should mention the missing path
        let hrd004 = results.first { $0.checkId == .HRD004 }
        XCTAssertEqual(hrd004?.filePath, missingScriptPath)
    }

    // MARK: - HRD005: hook script not executable

    func testHRD005FiresWhenHookNotExecutable() async throws {
        let url = try writeHookFile(name: "claudoscope-validate-commands.sh", executable: false)
        try writeSettings([
            "sandbox": ["enabled": true],
            "permissions": ["deny": ConfigLinterService.hardeningDenyBaseline],
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": "Bash",
                        "hooks": [
                            ["type": "command", "command": url.path]
                        ]
                    ]
                ]
            ]
        ])
        let results = await runLint()
        XCTAssertTrue(contains(results, .HRD005),
                      "HRD005 should fire when a registered hook file is not executable")
    }

    func testHRD005PassesWhenHookExecutable() async throws {
        let url = try writeHookFile(name: "claudoscope-validate-commands.sh", executable: true)
        try writeSettings([
            "sandbox": ["enabled": true],
            "permissions": ["deny": ConfigLinterService.hardeningDenyBaseline],
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": "Bash",
                        "hooks": [
                            ["type": "command", "command": url.path]
                        ]
                    ]
                ]
            ]
        ])
        let results = await runLint()
        XCTAssertFalse(contains(results, .HRD005),
                       "HRD005 should not fire when hook file is executable")
    }

    // MARK: - HRD006: SHA drift on bundled hooks

    /// HRD006 reads the bundled `layer2-hooks.sha256` sidecar via
    /// `Bundle.main.url(...)`. In the SPM test runner that lookup returns nil
    /// (the linter falls back to "skip silently" — see the `break` in the
    /// HRD006 loop). This test verifies that fallback path: a tampered
    /// `claudoscope-*.sh` does NOT produce HRD006 when the bundled sidecar is
    /// unreachable. End-to-end drift detection is verified manually per the
    /// plan's Verification section.
    func testHRD006SkipsWhenSidecarUnreachable() async throws {
        // Place a "tampered" claudoscope-*.sh in the hooks dir
        let url = try writeHookFile(name: "claudoscope-validate-commands.sh", executable: true,
                                    body: "#!/bin/bash\n# tampered\nexit 1\n")
        try writeSettings([
            "sandbox": ["enabled": true],
            "permissions": ["deny": ConfigLinterService.hardeningDenyBaseline],
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": "Bash",
                        "hooks": [["type": "command", "command": url.path]]
                    ]
                ]
            ]
        ])
        let results = await runLint()
        // HRD006 should NOT fire because the bundled sidecar is not reachable
        // from the test runner's Bundle.main.
        XCTAssertFalse(contains(results, .HRD006),
                       "HRD006 should silently skip when bundled sidecar is unreachable in test environment")
    }

    // MARK: - HRD007: world-writable hook file

    func testHRD007FiresWhenWorldWritable() async throws {
        let url = try writeHookFile(name: "claudoscope-validate-commands.sh",
                                    executable: true, worldWritable: true)
        try writeSettings([
            "sandbox": ["enabled": true],
            "permissions": ["deny": ConfigLinterService.hardeningDenyBaseline],
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": "Bash",
                        "hooks": [["type": "command", "command": url.path]]
                    ]
                ]
            ]
        ])
        let results = await runLint()
        XCTAssertTrue(contains(results, .HRD007),
                      "HRD007 should fire on a world-writable hook script")
    }

    // MARK: - HRD008: autoMode missing

    func testHRD008FiresWhenAutoModeMissing() async throws {
        try writeSettings([
            "sandbox": ["enabled": true],
            "permissions": ["deny": ConfigLinterService.hardeningDenyBaseline]
        ])
        let results = await runLint()
        XCTAssertTrue(contains(results, .HRD008),
                      "HRD008 should fire when autoMode is missing from settings.json")
    }

    func testHRD008DoesNotFireWhenAutoModePresent() async throws {
        try writeFullySatisfyingSettings()
        let results = await runLint()
        XCTAssertFalse(contains(results, .HRD008),
                       "HRD008 should not fire when autoMode block is present")
    }

    // MARK: - HRD009: wildcard environment / network entries

    func testHRD009FiresOnWildcardEnvironmentEntry() async throws {
        try writeSettings([
            "sandbox": ["enabled": true],
            "permissions": ["deny": ConfigLinterService.hardeningDenyBaseline],
            "autoMode": ["environment": ["*", "github.com"]]
        ])
        let results = await runLint()
        XCTAssertTrue(contains(results, .HRD009),
                      "HRD009 should fire on '*' wildcard in autoMode.environment")
    }

    func testHRD009FiresOnWildcardAllowedHost() async throws {
        try writeSettings([
            "sandbox": [
                "enabled": true,
                "network": ["allowedHosts": ["https://"]]
            ],
            "permissions": ["deny": ConfigLinterService.hardeningDenyBaseline]
        ])
        let results = await runLint()
        XCTAssertTrue(contains(results, .HRD009),
                      "HRD009 should fire on 'https://' literal in sandbox.network.allowedHosts")
    }

    // MARK: - HRD010: governance block

    func testHRD010FiresWhenGovernanceMarkersMissing() async throws {
        try writeFullySatisfyingSettings()
        // Overwrite CLAUDE.md without the markers
        try writeCLAUDEMd("# My CLAUDE.md\n\nSome text without markers.\n")
        let results = await runLint()
        XCTAssertTrue(contains(results, .HRD010),
                      "HRD010 should fire when governance BEGIN marker is absent from CLAUDE.md")
    }

    func testHRD010FiresWhenClaudeMdMissing() async throws {
        // Don't create CLAUDE.md at all
        try writeSettings([
            "sandbox": ["enabled": true],
            "permissions": ["deny": ConfigLinterService.hardeningDenyBaseline]
        ])
        let results = await runLint()
        XCTAssertTrue(contains(results, .HRD010),
                      "HRD010 should fire when CLAUDE.md is missing entirely")
    }

    /// When markers ARE present, HRD010 should not fire as a missing-block
    /// result. The drift sub-case (bundled hash comparison) silently skips
    /// when the bundle is unreachable, so no HRD010 of any kind should fire.
    func testHRD010DoesNotFireWhenMarkersPresent() async throws {
        try writeFullySatisfyingSettings()
        let results = await runLint()
        XCTAssertFalse(contains(results, .HRD010),
                       "HRD010 should not fire when markers are present and bundle drift check is unreachable")
    }

    // MARK: - HRD011: skipped, bundle-dependent
    // HRD011 reads `~/.claude/skills/claudoscope-security-awareness.md` and
    // compares against the bundled sidecar. The "missing skill" path would fire
    // here, but the drift path requires `Bundle.main` access and is verified
    // manually via the plan's Verification section.

    // MARK: - HRD012: autoMode present but hard_deny missing or empty

    func testHRD012FiresWhenAutoModePresentWithoutHardDeny() async throws {
        try writeFullySatisfyingSettings(extra: [
            "autoMode": ["environment": ["$defaults"]]
            // hard_deny key intentionally absent
        ])
        let results = await runLint()
        XCTAssertTrue(contains(results, .HRD012),
                      "HRD012 should fire when autoMode is present but hard_deny is absent")
    }

    func testHRD012FiresWhenAutoModePresentWithEmptyHardDeny() async throws {
        try writeFullySatisfyingSettings(extra: [
            "autoMode": ["environment": ["$defaults"], "hard_deny": [String]()]
        ])
        let results = await runLint()
        XCTAssertTrue(contains(results, .HRD012),
                      "HRD012 should fire when autoMode is present but hard_deny is empty")
    }

    func testHRD012DoesNotFireWhenHardDenyPopulated() async throws {
        try writeFullySatisfyingSettings(extra: [
            "autoMode": ["environment": ["$defaults"], "hard_deny": ["Bash(rm *)"]]
        ])
        let results = await runLint()
        XCTAssertFalse(contains(results, .HRD012),
                       "HRD012 should not fire when hard_deny has at least one entry")
    }

    func testHRD012DoesNotFireWhenAutoModeAbsent() async throws {
        // No autoMode block at all — HRD008 fires instead, not HRD012.
        try writeSettings([
            "sandbox": ["enabled": true],
            "permissions": ["deny": ConfigLinterService.hardeningDenyBaseline]
        ])
        let results = await runLint()
        XCTAssertFalse(contains(results, .HRD012),
                       "HRD012 should not fire when autoMode is not present")
    }

    // MARK: - CFG008: allowAllClaudeAiMcps enabled

    private func runLintConfig() async -> [LintResult] {
        let linter = ConfigLinterService()
        return await linter.lintConfig(globalClaudeDir: tempDir, projectRoot: nil)
    }

    func testCFG008FiresWhenAllowAllClaudeAiMcpsTrue() async throws {
        try writeSettings(["allowAllClaudeAiMcps": true])
        let results = await runLintConfig()
        XCTAssertTrue(contains(results, .CFG008),
                      "CFG008 should fire when allowAllClaudeAiMcps is true")
    }

    func testCFG008DoesNotFireWhenAllowAllClaudeAiMcpsFalse() async throws {
        try writeSettings(["allowAllClaudeAiMcps": false])
        let results = await runLintConfig()
        XCTAssertFalse(contains(results, .CFG008),
                       "CFG008 should not fire when allowAllClaudeAiMcps is false")
    }

    func testCFG008DoesNotFireWhenAllowAllClaudeAiMcpsAbsent() async throws {
        try writeSettings([:])
        let results = await runLintConfig()
        XCTAssertFalse(contains(results, .CFG008),
                       "CFG008 should not fire when allowAllClaudeAiMcps is absent")
    }
}

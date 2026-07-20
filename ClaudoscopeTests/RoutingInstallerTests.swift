import XCTest
@testable import Claudoscope

/// Records gate-closure calls on the main actor for the install-gate test.
@MainActor
private final class RoutingGateRecorder {
    var calls: [Bool] = []
    func record(_ value: Bool) { calls.append(value) }
}

/// Exercises `RoutingStackInstaller` against a temporary `~/.claude/`. Unlike
/// `HardeningInstaller`, the payload is injected as a value (not read from
/// `Bundle.main`), so the full install/revert/uninstall happy path runs under
/// `swift test` with no bundle dependency.
@MainActor
final class RoutingInstallerTests: XCTestCase {
    var tempDir: URL!
    var installer: RoutingStackInstaller!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RoutingInstallerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        installer = makeInstaller()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func makePayload(fallbackModel: [String]? = ["opus", "sonnet"]) -> RoutingStackPayload {
        var agentFiles: [RoutingStackPayload.AgentFile] = []
        for name in RoutingStackPayloadLoader.coreAgentFileNames {
            agentFiles.append(.init(fileName: name, group: .core, content: "core agent: \(name)\n"))
        }
        for name in RoutingStackPayloadLoader.securityAgentFileNames {
            agentFiles.append(.init(fileName: name, group: .security, content: "security agent: \(name)\n"))
        }
        return RoutingStackPayload(
            agentFiles: agentFiles,
            policyCoreFragment: "CORE POLICY FRAGMENT",
            policySecurityFragment: "SECURITY POLICY SENTINEL",
            fallbackModel: fallbackModel
        )
    }

    private func makeInstaller(
        payload: RoutingStackPayload? = nil,
        gate: @escaping @Sendable @MainActor (Bool) -> Void = { _ in }
    ) -> RoutingStackInstaller {
        let resolvedPayload = payload ?? makePayload()
        return RoutingStackInstaller(
            claudeDir: tempDir,
            payloadProvider: { resolvedPayload },
            setInstallInProgress: gate
        )
    }

    private func writeJSON(_ obj: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
        try data.write(to: url)
    }

    private func writeText(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private var settingsURL: URL { tempDir.appendingPathComponent("settings.json") }
    private var claudeMdURL: URL { tempDir.appendingPathComponent("CLAUDE.md") }
    private var agentsDir: URL { tempDir.appendingPathComponent("agents") }
    private var markerURL: URL { tempDir.appendingPathComponent(RoutingStackInstaller.markerFileName) }
    private var allAgentNames: [String] {
        RoutingStackPayloadLoader.coreAgentFileNames + RoutingStackPayloadLoader.securityAgentFileNames
    }

    // MARK: 1. Full install on empty dir

    func testFullInstallOnEmptyDir() async throws {
        let result = try await installer.install(options: RoutingInstallOptions())

        for name in allAgentNames {
            let url = agentsDir.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(name) should be installed")
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.uint16Value, 0o644)
        }

        let claudeMd = try String(contentsOf: claudeMdURL, encoding: .utf8)
        XCTAssertEqual(claudeMd.components(separatedBy: RoutingStackInstaller.policyBeginMarker).count - 1, 1)
        XCTAssertTrue(claudeMd.contains("SECURITY POLICY SENTINEL"))

        let settings = try readJSON(settingsURL)
        XCTAssertEqual(settings["fallbackModel"] as? [String], ["opus", "sonnet"])

        let marker = try readJSON(markerURL)
        XCTAssertEqual(marker["coreInstalled"] as? Bool, true)
        XCTAssertEqual(marker["securityInstalled"] as? Bool, true)
        XCTAssertEqual(marker["policyInstalled"] as? Bool, true)
        XCTAssertEqual(marker["fallbackModelSet"] as? Bool, true)
        XCTAssertEqual((marker["agentHashes"] as? [String: String])?.count, 7)

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.backupPath.path))
    }

    // MARK: 2. Core-only install

    func testCoreOnlyInstall() async throws {
        _ = try await installer.install(options: RoutingInstallOptions(
            coreAgents: true, securityAgents: false, policyBlock: true, settingsFallbackModel: true
        ))

        for name in RoutingStackPayloadLoader.coreAgentFileNames {
            XCTAssertTrue(FileManager.default.fileExists(atPath: agentsDir.appendingPathComponent(name).path))
        }
        for name in RoutingStackPayloadLoader.securityAgentFileNames {
            XCTAssertFalse(FileManager.default.fileExists(atPath: agentsDir.appendingPathComponent(name).path))
        }

        let claudeMd = try String(contentsOf: claudeMdURL, encoding: .utf8)
        XCTAssertFalse(claudeMd.contains("SECURITY POLICY SENTINEL"))
        XCTAssertTrue(claudeMd.contains("CORE POLICY FRAGMENT"))

        let marker = try readJSON(markerURL)
        XCTAssertEqual(marker["securityInstalled"] as? Bool, false)
    }

    // MARK: 3. Security-only install

    func testSecurityOnlyInstall() async throws {
        _ = try await installer.install(options: RoutingInstallOptions(
            coreAgents: false, securityAgents: true, policyBlock: true, settingsFallbackModel: true
        ))

        for name in RoutingStackPayloadLoader.securityAgentFileNames {
            XCTAssertTrue(FileManager.default.fileExists(atPath: agentsDir.appendingPathComponent(name).path))
        }
        for name in RoutingStackPayloadLoader.coreAgentFileNames {
            XCTAssertFalse(FileManager.default.fileExists(atPath: agentsDir.appendingPathComponent(name).path))
        }

        let claudeMd = try String(contentsOf: claudeMdURL, encoding: .utf8)
        XCTAssertTrue(claudeMd.contains("CORE POLICY FRAGMENT"), "policy always includes the core fragment")
        XCTAssertTrue(claudeMd.contains("SECURITY POLICY SENTINEL"))
    }

    // MARK: 4. Reinstall idempotency

    func testReinstallIdempotency() async throws {
        _ = try await installer.install(options: RoutingInstallOptions())
        let markerBefore = try readJSON(markerURL)
        let settingsBefore = try Data(contentsOf: settingsURL)
        let claudeMdBefore = try Data(contentsOf: claudeMdURL)

        _ = try await installer.install(options: RoutingInstallOptions())

        XCTAssertEqual(try Data(contentsOf: settingsURL), settingsBefore, "reinstall must not change settings.json")
        XCTAssertEqual(try Data(contentsOf: claudeMdURL), claudeMdBefore, "reinstall must not change CLAUDE.md")

        let claudeMd = try String(contentsOf: claudeMdURL, encoding: .utf8)
        XCTAssertEqual(claudeMd.components(separatedBy: RoutingStackInstaller.policyBeginMarker).count - 1, 1)

        let markerAfter = try readJSON(markerURL)
        XCTAssertEqual(markerAfter["installedAt"] as? String, markerBefore["installedAt"] as? String)
        XCTAssertEqual(markerAfter["backupPath"] as? String, markerBefore["backupPath"] as? String)
    }

    // MARK: 5. Additive reinstall

    func testAdditiveReinstallUpgradesPolicyAndMergesGroups() async throws {
        _ = try await installer.install(options: RoutingInstallOptions(
            coreAgents: true, securityAgents: false, policyBlock: true, settingsFallbackModel: true
        ))
        var claudeMd = try String(contentsOf: claudeMdURL, encoding: .utf8)
        XCTAssertFalse(claudeMd.contains("SECURITY POLICY SENTINEL"))

        _ = try await installer.install(options: RoutingInstallOptions(
            coreAgents: false, securityAgents: true, policyBlock: true, settingsFallbackModel: true
        ))
        claudeMd = try String(contentsOf: claudeMdURL, encoding: .utf8)
        XCTAssertTrue(claudeMd.contains("SECURITY POLICY SENTINEL"), "policy upgrades once security agents are installed")
        XCTAssertEqual(claudeMd.components(separatedBy: RoutingStackInstaller.policyBeginMarker).count - 1, 1)

        let marker = try readJSON(markerURL)
        XCTAssertEqual(marker["coreInstalled"] as? Bool, true)
        XCTAssertEqual(marker["securityInstalled"] as? Bool, true)
        XCTAssertEqual((marker["agentHashes"] as? [String: String])?.count, 7, "hashes from both installs are unioned")

        for name in allAgentNames {
            XCTAssertTrue(FileManager.default.fileExists(atPath: agentsDir.appendingPathComponent(name).path))
        }
    }

    // MARK: 6. fallbackModel set-if-absent

    func testFallbackModelSetIfAbsent() async throws {
        try writeJSON(["fallbackModel": ["haiku"]], to: settingsURL)

        _ = try await installer.install(options: RoutingInstallOptions())

        let settings = try readJSON(settingsURL)
        XCTAssertEqual(settings["fallbackModel"] as? [String], ["haiku"], "pre-seeded fallbackModel must be untouched")

        let marker = try readJSON(markerURL)
        XCTAssertEqual(marker["fallbackModelSet"] as? Bool, false)

        let report = try await installer.uninstall(deleteBackups: false)
        XCTAssertFalse(report.fallbackModelRemoved)
        XCTAssertEqual(try readJSON(settingsURL)["fallbackModel"] as? [String], ["haiku"],
                       "uninstall must leave a value it didn't set")
    }

    // MARK: 7. `model` never touched (hard invariant)

    func testModelNeverTouched() async throws {
        try writeJSON(["model": "fable", "otherKey": "unchanged"], to: settingsURL)

        _ = try await installer.install(options: RoutingInstallOptions())
        XCTAssertEqual(try readJSON(settingsURL)["model"] as? String, "fable")

        _ = try await installer.uninstall(deleteBackups: false)
        XCTAssertEqual(try readJSON(settingsURL)["model"] as? String, "fable")

        _ = try await installer.install(options: RoutingInstallOptions())
        XCTAssertEqual(try readJSON(settingsURL)["model"] as? String, "fable")

        try await installer.revert()
        let restored = try readJSON(settingsURL)
        XCTAssertEqual(restored["model"] as? String, "fable")
        XCTAssertEqual(restored["otherKey"] as? String, "unchanged")
    }

    // MARK: 8. Malformed settings refusal

    func testMalformedSettingsRefusal() async throws {
        let bad = "{not json}"
        try writeText(bad, to: settingsURL)

        do {
            _ = try await installer.install(options: RoutingInstallOptions())
            XCTFail("install should have thrown")
        } catch RoutingInstallError.malformedSettingsJson {
            // expected
        } catch {
            XCTFail("expected malformedSettingsJson, got \(error)")
        }

        XCTAssertEqual(try String(contentsOf: settingsURL, encoding: .utf8), bad,
                       "malformed settings.json must be left untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeMdURL.path), "CLAUDE.md must not be created")
        XCTAssertFalse(FileManager.default.fileExists(atPath: agentsDir.path), "no agent files should be written")

        let entries = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        let names = Set(entries.map { $0.lastPathComponent })
        XCTAssertTrue(names.contains("settings.json"))
        XCTAssertTrue(names.contains { $0.hasPrefix(RoutingStackInstaller.backupPrefix) })
    }

    // MARK: 9. User collision

    func testUserCollisionPreflightBackupAndRevert() async throws {
        try writeText("USER'S OWN RECON FILE\n", to: agentsDir.appendingPathComponent("recon.md"))

        let preflight = try await installer.preflight()
        let reconItem = preflight.agentItems.first { $0.fileName == "recon.md" }
        XCTAssertEqual(reconItem?.status, .willOverwriteDiffering)

        _ = try await installer.install(options: RoutingInstallOptions())
        let installed = try String(contentsOf: agentsDir.appendingPathComponent("recon.md"), encoding: .utf8)
        XCTAssertNotEqual(installed, "USER'S OWN RECON FILE\n")

        try await installer.revert()
        let restored = try String(contentsOf: agentsDir.appendingPathComponent("recon.md"), encoding: .utf8)
        XCTAssertEqual(restored, "USER'S OWN RECON FILE\n", "revert restores the user's original file")
    }

    // MARK: 10. Conservative uninstall

    func testConservativeUninstallKeepsUserEditedFile() async throws {
        _ = try await installer.install(options: RoutingInstallOptions())

        try writeText("USER EDITED AFTER INSTALL\n", to: agentsDir.appendingPathComponent("builder.md"))

        let report = try await installer.uninstall(deleteBackups: false)

        XCTAssertTrue(report.keptUserEditedFiles.contains("builder.md"))
        XCTAssertFalse(report.removedFiles.contains("builder.md"))
        XCTAssertEqual(report.removedFiles.count, 6)
        XCTAssertTrue(report.policyBlockRemoved)
        XCTAssertTrue(report.fallbackModelRemoved)

        XCTAssertEqual(
            try String(contentsOf: agentsDir.appendingPathComponent("builder.md"), encoding: .utf8),
            "USER EDITED AFTER INSTALL\n"
        )
        for name in allAgentNames where name != "builder.md" {
            XCTAssertFalse(FileManager.default.fileExists(atPath: agentsDir.appendingPathComponent(name).path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testUninstallBacksUpBeforeStripping() async throws {
        _ = try await installer.install(options: RoutingInstallOptions())
        XCTAssertTrue(
            try String(contentsOf: claudeMdURL, encoding: .utf8).contains(RoutingStackInstaller.policyBeginMarker),
            "sanity: policy block present before uninstall"
        )

        _ = try await installer.uninstall(deleteBackups: false)

        // Live files no longer carry our artifacts.
        XCTAssertFalse(try String(contentsOf: claudeMdURL, encoding: .utf8).contains(RoutingStackInstaller.policyBeginMarker))
        XCTAssertNil(try readJSON(settingsURL)["fallbackModel"])

        // A backup captured the pre-uninstall state (settings.json fallbackModel +
        // CLAUDE.md policy block). Robust to same-second install/uninstall timestamps:
        // whichever backup dir holds it, one of them must.
        let backups = InstallerFileOps.backupDirectories(in: tempDir, prefix: RoutingStackInstaller.backupPrefix)
        XCTAssertFalse(backups.isEmpty, "uninstall must leave a safety backup before stripping")
        let captured = backups.contains { dir in
            let fallback = (try? readJSON(dir.appendingPathComponent("settings.json")))?["fallbackModel"] as? [String]
            let md = try? String(contentsOf: dir.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
            return fallback == ["opus", "sonnet"] && (md?.contains(RoutingStackInstaller.policyBeginMarker) ?? false)
        }
        XCTAssertTrue(captured, "a backup must contain the pre-uninstall settings.json + CLAUDE.md")
    }

    // MARK: 11. Uninstall recognizes files after a payload content change

    func testUninstallRecognizesFilesAfterPayloadChange() async throws {
        let payloadA = makePayload()
        let installerA = makeInstaller(payload: payloadA)
        _ = try await installerA.install(options: RoutingInstallOptions())

        let updatedRecon = RoutingStackPayload.AgentFile(
            fileName: "recon.md", group: .core, content: "core agent: recon.md UPDATED\n"
        )
        var newAgentFiles = payloadA.agentFiles.filter { $0.fileName != "recon.md" }
        newAgentFiles.append(updatedRecon)
        let payloadB = RoutingStackPayload(
            agentFiles: newAgentFiles,
            policyCoreFragment: payloadA.policyCoreFragment,
            policySecurityFragment: payloadA.policySecurityFragment,
            fallbackModel: payloadA.fallbackModel
        )
        let installerB = makeInstaller(payload: payloadB)

        // Simulate a Reinstall-after-app-upgrade: the live file now matches
        // payload B's content, but the marker's agentHashes still records
        // payload A's hash (only installerB's uninstall call recomputes hashes).
        try writeText(updatedRecon.content, to: agentsDir.appendingPathComponent("recon.md"))

        let report = try await installerB.uninstall(deleteBackups: false)
        XCTAssertTrue(report.removedFiles.contains("recon.md"),
                      "a file matching the CURRENT payload hash is still recognized as ours")
    }

    // MARK: 12. Revert without/with marker

    func testRevertWithoutMarkerThrows() async throws {
        do {
            try await installer.revert()
            XCTFail("revert should have thrown")
        } catch RoutingInstallError.noMarkerForRevert {
            // expected
        } catch {
            XCTFail("expected noMarkerForRevert, got \(error)")
        }
    }

    func testRevertWithMarkerRestoresPreInstallState() async throws {
        try writeJSON(["existingKey": "keepme"], to: settingsURL)
        try writeText("# pre-existing CLAUDE.md\n", to: claudeMdURL)

        _ = try await installer.install(options: RoutingInstallOptions())
        try await installer.revert()

        let settings = try readJSON(settingsURL)
        XCTAssertEqual(settings["existingKey"] as? String, "keepme")
        XCTAssertNil(settings["fallbackModel"])

        XCTAssertEqual(try String(contentsOf: claudeMdURL, encoding: .utf8), "# pre-existing CLAUDE.md\n")

        for name in allAgentNames {
            XCTAssertFalse(FileManager.default.fileExists(atPath: agentsDir.appendingPathComponent(name).path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }

    // MARK: 13. Gate closure

    func testGateClosureRecordsInstallLifecycle() async throws {
        let recorder = RoutingGateRecorder()
        let inst = makeInstaller(gate: { v in recorder.record(v) })
        _ = try await inst.install(options: RoutingInstallOptions())
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(recorder.calls, [true, false])
    }

    // MARK: 14. Pure functions

    func testAssemblePolicyConcatenation() async throws {
        let payload = makePayload()
        let withSecurity = await installer.assemblePolicy(payload: payload, includeSecurity: true)
        XCTAssertTrue(withSecurity.contains("CORE POLICY FRAGMENT"))
        XCTAssertTrue(withSecurity.contains("SECURITY POLICY SENTINEL"))

        let withoutSecurity = await installer.assemblePolicy(payload: payload, includeSecurity: false)
        XCTAssertTrue(withoutSecurity.contains("CORE POLICY FRAGMENT"))
        XCTAssertFalse(withoutSecurity.contains("SECURITY POLICY SENTINEL"))
    }

    func testStripAndAppendMarkerBlockIdempotenceAndPreservation() {
        let begin = "<!-- BEGIN: test -->"
        let end = "<!-- END: test -->"

        let original = "Above content\n\nBelow content\n"
        let withBlock = InstallerFileOps.appendMarkerBlock(to: original, body: "BODY V1", begin: begin, end: end)
        XCTAssertTrue(withBlock.contains("BODY V1"))
        XCTAssertTrue(withBlock.contains("Above content"))
        XCTAssertTrue(withBlock.contains("Below content"))

        let upgraded = InstallerFileOps.appendMarkerBlock(to: withBlock, body: "BODY V2", begin: begin, end: end)
        XCTAssertFalse(upgraded.contains("BODY V1"))
        XCTAssertTrue(upgraded.contains("BODY V2"))
        XCTAssertEqual(upgraded.components(separatedBy: begin).count - 1, 1, "exactly one block after re-append")
        XCTAssertTrue(upgraded.contains("Above content"))
        XCTAssertTrue(upgraded.contains("Below content"))

        let stripped = InstallerFileOps.stripMarkerBlock(from: upgraded, begin: begin, end: end)
        XCTAssertFalse(stripped.contains(begin))
        XCTAssertFalse(stripped.contains("BODY V2"))
        XCTAssertTrue(stripped.contains("Above content"))
        XCTAssertTrue(stripped.contains("Below content"))

        let strippedAgain = InstallerFileOps.stripMarkerBlock(from: stripped, begin: begin, end: end)
        XCTAssertEqual(stripped, strippedAgain, "stripping an already-clean text is a no-op")
    }
}

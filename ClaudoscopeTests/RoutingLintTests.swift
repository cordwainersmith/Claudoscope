import XCTest
@testable import Claudoscope

/// Per-rule tests for the RTG lint family. Each test seeds a synthetic
/// `~/.claude/`-style temp directory plus an inline `RoutingStackPayload`
/// (no `Bundle.main` dependency) and asserts which RTG checks fire.
final class RoutingLintTests: XCTestCase {
    var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RoutingLintTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - Helpers

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
            policySecurityFragment: "SECURITY POLICY SENTINEL security-review security-build",
            fallbackModel: fallbackModel
        )
    }

    private func markerBase(
        coreInstalled: Bool = true,
        securityInstalled: Bool = false,
        policyInstalled: Bool = true,
        fallbackModelSet: Bool = false,
        fallbackModelValue: [String]? = nil,
        agentHashes: [String: String] = [:]
    ) -> [String: Any] {
        var marker: [String: Any] = [
            "version": "1",
            "installedAt": "2026-07-20T00:00:00.000Z",
            "backupPath": tempDir.appendingPathComponent(".claudoscope-routing-backup-test").path,
            "coreInstalled": coreInstalled,
            "securityInstalled": securityInstalled,
            "policyInstalled": policyInstalled,
            "fallbackModelSet": fallbackModelSet,
            "agentHashes": agentHashes,
        ]
        if let v = fallbackModelValue { marker["fallbackModelValue"] = v }
        return marker
    }

    private func writeMarker(_ obj: [String: Any]) throws {
        let url = tempDir.appendingPathComponent(ConfigLinterService.routingMarkerFileName)
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
        try data.write(to: url)
    }

    private func writeSettings(_ obj: [String: Any]) throws {
        let url = tempDir.appendingPathComponent("settings.json")
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
        try data.write(to: url)
    }

    private func writeCLAUDEMd(_ body: String) throws {
        try body.write(to: tempDir.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
    }

    private func writeAgentFile(_ name: String, content: String) throws {
        let url = tempDir.appendingPathComponent("agents").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func runLint(payload: RoutingStackPayload?) async -> [LintResult] {
        let linter = ConfigLinterService()
        return await linter.lintRouting(globalClaudeDir: tempDir, payload: payload)
    }

    // MARK: - Not installed

    func testNoMarkerYieldsNoResults() async throws {
        let results = await runLint(payload: makePayload())
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - RTG001 / RTG002 (agent presence + drift)

    func testRTG001FiresForMissingAgentFile() async throws {
        let payload = makePayload()
        var hashes: [String: String] = [:]
        for name in RoutingStackPayloadLoader.coreAgentFileNames {
            hashes[name] = payload.contentHash(forAgent: name)
            guard name != "checker.md" else { continue }
            try writeAgentFile(name, content: payload.agentFiles.first { $0.fileName == name }!.content)
        }
        try writeMarker(markerBase(coreInstalled: true, securityInstalled: false, policyInstalled: false, agentHashes: hashes))

        let results = await runLint(payload: payload)
        XCTAssertTrue(results.contains { $0.checkId == .RTG001 && $0.filePath.hasSuffix("checker.md") })
        XCTAssertFalse(results.contains { $0.checkId == .RTG001 && $0.filePath.hasSuffix("recon.md") })
    }

    func testRTG002FiresOnDrift() async throws {
        let payload = makePayload()
        var hashes: [String: String] = [:]
        for name in RoutingStackPayloadLoader.coreAgentFileNames {
            let content = payload.agentFiles.first { $0.fileName == name }!.content
            hashes[name] = payload.contentHash(forAgent: name)
            try writeAgentFile(name, content: content)
        }
        // Drift one file: differs from both the recorded marker hash and the current payload hash.
        try writeAgentFile("recon.md", content: "SOMETHING ELSE ENTIRELY\n")
        try writeMarker(markerBase(coreInstalled: true, agentHashes: hashes))

        let results = await runLint(payload: payload)
        XCTAssertTrue(results.contains { $0.checkId == .RTG002 && $0.filePath.hasSuffix("recon.md") })
        XCTAssertFalse(results.contains { $0.checkId == .RTG002 && $0.filePath.hasSuffix("builder.md") })
    }

    // MARK: - RTG003 (policy block presence + drift)

    func testRTG003FiresWhenPolicyBlockMissing() async throws {
        try writeMarker(markerBase(coreInstalled: true, securityInstalled: false, policyInstalled: true))
        let results = await runLint(payload: makePayload())
        XCTAssertTrue(results.contains { $0.checkId == .RTG003 })
    }

    func testRTG003FiresWhenPolicyBlockDrifted() async throws {
        let begin = ConfigLinterService.routingPolicyBeginMarker
        let end = ConfigLinterService.routingPolicyEndMarker
        try writeCLAUDEMd("Pre\n\n\(begin)\nSTALE BODY\n\(end)\n\nPost\n")
        try writeMarker(markerBase(coreInstalled: true, securityInstalled: false, policyInstalled: true))

        let results = await runLint(payload: makePayload())
        XCTAssertTrue(results.contains { $0.checkId == .RTG003 })
    }

    func testRTG003DoesNotFireWhenPolicyMatches() async throws {
        let payload = makePayload()
        let begin = ConfigLinterService.routingPolicyBeginMarker
        let end = ConfigLinterService.routingPolicyEndMarker
        let body = payload.policyBody(includeSecurity: false)
        try writeCLAUDEMd("\n\n\(begin)\n\(body)\n\(end)\n")
        try writeMarker(markerBase(coreInstalled: true, securityInstalled: false, policyInstalled: true))

        let results = await runLint(payload: payload)
        XCTAssertFalse(results.contains { $0.checkId == .RTG003 })
    }

    // MARK: - RTG004 (policy/agents inconsistency)

    func testRTG004FiresWhenPolicyMentionsSecurityButNotInstalled() async throws {
        let payload = makePayload()
        let begin = ConfigLinterService.routingPolicyBeginMarker
        let end = ConfigLinterService.routingPolicyEndMarker
        let body = payload.policyBody(includeSecurity: true)
        try writeCLAUDEMd("\n\n\(begin)\n\(body)\n\(end)\n")
        try writeMarker(markerBase(coreInstalled: true, securityInstalled: false, policyInstalled: true))

        let results = await runLint(payload: payload)
        XCTAssertTrue(results.contains { $0.checkId == .RTG004 })
    }

    func testRTG004DoesNotFireWhenConsistent() async throws {
        let payload = makePayload()
        let begin = ConfigLinterService.routingPolicyBeginMarker
        let end = ConfigLinterService.routingPolicyEndMarker
        let body = payload.policyBody(includeSecurity: true)
        try writeCLAUDEMd("\n\n\(begin)\n\(body)\n\(end)\n")
        try writeMarker(markerBase(coreInstalled: true, securityInstalled: true, policyInstalled: true))

        let results = await runLint(payload: payload)
        XCTAssertFalse(results.contains { $0.checkId == .RTG004 })
    }

    // MARK: - RTG005 (fallbackModel drift)

    func testRTG005FiresWhenFallbackModelChanged() async throws {
        try writeSettings(["fallbackModel": ["haiku"]])
        try writeMarker(markerBase(fallbackModelSet: true, fallbackModelValue: ["opus", "sonnet"]))

        let results = await runLint(payload: makePayload())
        XCTAssertTrue(results.contains { $0.checkId == .RTG005 })
    }

    func testRTG005DoesNotFireWhenUnchanged() async throws {
        try writeSettings(["fallbackModel": ["opus", "sonnet"]])
        try writeMarker(markerBase(fallbackModelSet: true, fallbackModelValue: ["opus", "sonnet"]))

        let results = await runLint(payload: makePayload())
        XCTAssertFalse(results.contains { $0.checkId == .RTG005 })
    }

    func testRTG005DoesNotFireWhenWeNeverSetIt() async throws {
        try writeSettings(["fallbackModel": ["haiku"]])
        try writeMarker(markerBase(fallbackModelSet: false))

        let results = await runLint(payload: makePayload())
        XCTAssertFalse(results.contains { $0.checkId == .RTG005 })
    }

    // MARK: - RTG006 / RTG007 (env conflicts)

    func testRTG006And007FireOnEnvConflicts() async throws {
        try writeSettings(["env": ["ANTHROPIC_MODEL": "opus", "CLAUDE_CODE_SUBAGENT_MODEL": "sonnet"]])
        try writeMarker(markerBase())

        let results = await runLint(payload: makePayload())
        XCTAssertTrue(results.contains { $0.checkId == .RTG006 })
        XCTAssertTrue(results.contains { $0.checkId == .RTG007 })
    }

    func testRTG006And007AbsentWhenEnvClean() async throws {
        try writeSettings([:])
        try writeMarker(markerBase())

        let results = await runLint(payload: makePayload())
        XCTAssertFalse(results.contains { $0.checkId == .RTG006 })
        XCTAssertFalse(results.contains { $0.checkId == .RTG007 })
    }

    // MARK: - Nil payload (bundle unreachable)

    func testNilPayloadSkipsDriftButKeepsPresenceAndEnvChecks() async throws {
        try writeAgentFile("recon.md", content: "some content\n")
        try writeSettings(["env": ["ANTHROPIC_MODEL": "opus"]])
        let begin = ConfigLinterService.routingPolicyBeginMarker
        let end = ConfigLinterService.routingPolicyEndMarker
        try writeCLAUDEMd("\n\n\(begin)\nWHATEVER BODY\n\(end)\n")
        let hashes: [String: String] = ["recon.md": "deadbeef"]  // deliberately wrong; would drift if checked
        try writeMarker(markerBase(coreInstalled: true, securityInstalled: false, policyInstalled: true, agentHashes: hashes))

        let results = await runLint(payload: nil)

        XCTAssertTrue(results.contains { $0.checkId == .RTG001 }, "presence check for missing files still runs without a payload")
        XCTAssertTrue(results.contains { $0.checkId == .RTG006 }, "env check still runs without a payload")
        XCTAssertFalse(results.contains { $0.checkId == .RTG002 }, "agent drift is payload-dependent and must skip")
        XCTAssertFalse(results.contains { $0.checkId == .RTG003 }, "policy block is present; drift (payload-dependent) must skip")
    }
}

import Foundation

extension ConfigLinterService {

    // MARK: - Agent Routing Stack Checks (RTG001-RTG007)

    static let routingMarkerFileName = ".claudoscope-routing-installed"
    static let routingPolicyBeginMarker = "<!-- BEGIN: claudoscope-agent-routing -->"
    static let routingPolicyEndMarker = "<!-- END: claudoscope-agent-routing -->"

    /// All checks are gated on the routing marker file: an uninstalled stack
    /// produces zero RTG noise. `payload` is nil when the bundle is
    /// unreachable (e.g. under `swift test`) — drift checks (RTG002, RTG003)
    /// skip silently in that case, mirroring the HRD006/HRD010/HRD011
    /// precedent; presence and env-conflict checks still run.
    func lintRouting(globalClaudeDir: URL, payload: RoutingStackPayload?) -> [LintResult] {
        var results: [LintResult] = []

        let markerURL = globalClaudeDir.appendingPathComponent(Self.routingMarkerFileName)
        guard let markerData = try? Data(contentsOf: markerURL),
              let marker = try? JSONSerialization.jsonObject(with: markerData) as? [String: Any] else {
            return results
        }

        let settingsURL = globalClaudeDir.appendingPathComponent("settings.json")
        let settingsPath = settingsURL.path
        let settingsJSON: [String: Any] = (try? Data(contentsOf: settingsURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        let coreInstalled = marker["coreInstalled"] as? Bool ?? false
        let securityInstalled = marker["securityInstalled"] as? Bool ?? false
        let policyInstalled = marker["policyInstalled"] as? Bool ?? false
        let agentHashes = Self.routingAgentHashes(in: marker)

        let agentsDir = globalClaudeDir.appendingPathComponent("agents")
        let fmgr = FileManager.default

        var expectedNames: [String] = []
        if coreInstalled { expectedNames.append(contentsOf: RoutingStackPayloadLoader.coreAgentFileNames) }
        if securityInstalled { expectedNames.append(contentsOf: RoutingStackPayloadLoader.securityAgentFileNames) }

        // RTG001 / RTG002: presence + drift per expected agent file
        for name in expectedNames {
            let fileURL = agentsDir.appendingPathComponent(name)
            let path = fileURL.path
            guard fmgr.fileExists(atPath: path) else {
                results.append(LintResult(
                    severity: .warning,
                    checkId: .RTG001,
                    filePath: path,
                    message: "Routing stack agent \"\(name)\" is missing from ~/.claude/agents/.",
                    fix: "Reinstall the agent routing stack to restore \(name)",
                    displayPath: "agents/\(name)"
                ))
                continue
            }

            guard let payload else { continue }  // bundle unreachable: presence already checked, skip drift
            guard let actualHash = try? InstallerFileOps.sha256(file: fileURL) else { continue }
            let matchesPayload = actualHash == payload.contentHash(forAgent: name)
            let matchesMarker = actualHash == agentHashes[name]
            if !matchesPayload && !matchesMarker {
                results.append(LintResult(
                    severity: .warning,
                    checkId: .RTG002,
                    filePath: path,
                    message: "Routing stack agent \"\(name)\" has drifted from the installed baseline.",
                    fix: "Reinstall the agent routing stack to refresh \(name)",
                    displayPath: "agents/\(name)"
                ))
            }
        }

        // RTG003: policy block presence + drift
        let claudeMdURL = globalClaudeDir.appendingPathComponent("CLAUDE.md")
        let claudeMdPath = claudeMdURL.path
        if policyInstalled {
            if let claudeMd = try? String(contentsOf: claudeMdURL, encoding: .utf8) {
                if let extractedBody = Self.extractRoutingPolicyBlock(from: claudeMd) {
                    if let payload {
                        let expectedBody = payload.policyBody(includeSecurity: securityInstalled)
                        if InstallerFileOps.sha256(of: extractedBody) != InstallerFileOps.sha256(of: expectedBody) {
                            results.append(LintResult(
                                severity: .warning,
                                checkId: .RTG003,
                                filePath: claudeMdPath,
                                message: "Agent routing policy block in ~/.claude/CLAUDE.md has drifted from the installed baseline.",
                                fix: "Reinstall the agent routing stack to refresh the policy block",
                                displayPath: "CLAUDE.md"
                            ))
                        }
                    }
                } else {
                    results.append(LintResult(
                        severity: .warning,
                        checkId: .RTG003,
                        filePath: claudeMdPath,
                        message: "Agent routing policy block is missing from ~/.claude/CLAUDE.md.",
                        fix: "Reinstall the agent routing stack to restore the policy block",
                        displayPath: "CLAUDE.md"
                    ))
                }
            } else {
                results.append(LintResult(
                    severity: .warning,
                    checkId: .RTG003,
                    filePath: claudeMdPath,
                    message: "~/.claude/CLAUDE.md does not exist, so the agent routing policy block is not present.",
                    fix: "Reinstall the agent routing stack to recreate the policy block",
                    displayPath: "CLAUDE.md"
                ))
            }
        }

        // RTG004: policy/agents inconsistency (payload-independent sentinel check)
        if policyInstalled,
           let claudeMd = try? String(contentsOf: claudeMdURL, encoding: .utf8),
           let extractedBody = Self.extractRoutingPolicyBlock(from: claudeMd) {
            let mentionsSecurity = extractedBody.contains("security-review") || extractedBody.contains("security-build")
            if mentionsSecurity != securityInstalled {
                results.append(LintResult(
                    severity: .warning,
                    checkId: .RTG004,
                    filePath: claudeMdPath,
                    message: "Agent routing policy block and installed security agents are inconsistent.",
                    fix: "Reinstall the agent routing stack to resynchronize the policy block",
                    displayPath: "CLAUDE.md"
                ))
            }
        }

        // RTG005: fallbackModel we set was changed or removed
        if let fallbackModelSet = marker["fallbackModelSet"] as? Bool, fallbackModelSet,
           let markerValue = marker["fallbackModelValue"] as? [String] {
            let liveValue = settingsJSON["fallbackModel"] as? [String]
            if liveValue != markerValue {
                results.append(LintResult(
                    severity: .info,
                    checkId: .RTG005,
                    filePath: settingsPath,
                    message: "fallbackModel set by the agent routing stack was changed or removed.",
                    fix: nil,
                    displayPath: "settings.json"
                ))
            }
        }

        // RTG006 / RTG007: env-var conflicts. Never auto-fixed, never written.
        let envSection = settingsJSON["env"] as? [String: Any]
        if envSection?["ANTHROPIC_MODEL"] != nil {
            results.append(LintResult(
                severity: .warning,
                checkId: .RTG006,
                filePath: settingsPath,
                message: "settings.json env.ANTHROPIC_MODEL overrides every per-agent model tier the routing stack sets.",
                fix: nil,
                displayPath: "settings.json"
            ))
        }
        if envSection?["CLAUDE_CODE_SUBAGENT_MODEL"] != nil {
            results.append(LintResult(
                severity: .warning,
                checkId: .RTG007,
                filePath: settingsPath,
                message: "settings.json env.CLAUDE_CODE_SUBAGENT_MODEL forces every subagent onto one model, defeating the routing stack's tiering.",
                fix: nil,
                displayPath: "settings.json"
            ))
        }

        return results
    }

    // MARK: - Routing Helpers

    static func routingAgentHashes(in marker: [String: Any]) -> [String: String] {
        guard let raw = marker["agentHashes"] as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in raw {
            if let s = value as? String { out[key] = s }
        }
        return out
    }

    static func extractRoutingPolicyBlock(from text: String) -> String? {
        guard let beginRange = text.range(of: routingPolicyBeginMarker) else { return nil }
        guard let endRange = text.range(of: routingPolicyEndMarker, range: beginRange.upperBound..<text.endIndex) else {
            return nil
        }
        let body = String(text[beginRange.upperBound..<endRange.lowerBound])
        return body.trimmingCharacters(in: .newlines)
    }
}

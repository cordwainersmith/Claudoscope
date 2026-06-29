import Foundation

extension ConfigLinterService {

    // MARK: - Config Health Checks

    func lintConfig(globalClaudeDir: URL, projectRoot: URL?) -> [LintResult] {
        var results: [LintResult] = []

        let settingsURL = globalClaudeDir.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return results
        }

        let settingsPath = settingsURL.path

        // CFG001: sandbox.enabled without dependency lock files
        if let sandbox = json["sandbox"] as? [String: Any],
           let enabled = sandbox["enabled"] as? Bool, enabled,
           let root = projectRoot {
            let lockFiles = [
                "package-lock.json", "yarn.lock", "pnpm-lock.yaml",
                "Pipfile.lock", "poetry.lock", "Gemfile.lock",
                "go.sum", "Cargo.lock", "Package.resolved"
            ]
            let hasLock = lockFiles.contains {
                fm.fileExists(atPath: root.appendingPathComponent($0).path)
            }
            if !hasLock {
                results.append(LintResult(
                    severity: .warning,
                    checkId: .CFG001,
                    filePath: settingsPath,
                    message: "sandbox.enabled is true but no dependency lock files found. Sandbox may silently disable if required tools are missing.",
                    fix: "Install project dependencies or verify sandbox compatibility",
                    displayPath: "settings.json"
                ))
            }
        }

        // CFG002: allowRead/denyRead consistency
        if let allowRead = json["allowRead"] as? [String],
           let denyRead = json["denyRead"] as? [String] {
            let conflicts = Set(allowRead).intersection(Set(denyRead))
            if !conflicts.isEmpty {
                results.append(LintResult(
                    severity: .warning,
                    checkId: .CFG002,
                    filePath: settingsPath,
                    message: "Contradictory filesystem permissions: \(conflicts.sorted().joined(separator: ", ")) appears in both allowRead and denyRead.",
                    fix: "Remove conflicting paths from one of the lists",
                    displayPath: "settings.json"
                ))
            }
        }

        // CFG003: ENABLE_CLAUDEAI_MCP_SERVERS disabled
        let envSection = json["env"] as? [String: Any]
        if let mcpVal = envSection?["ENABLE_CLAUDEAI_MCP_SERVERS"] as? String,
           mcpVal.lowercased() == "false" {
            results.append(LintResult(
                severity: .info,
                checkId: .CFG003,
                filePath: settingsPath,
                message: "ENABLE_CLAUDEAI_MCP_SERVERS is set to false. Claude.ai MCP servers are disabled.",
                displayPath: "settings.json"
            ))
        }

        // CFG004: allowedChannelPlugins configured
        if json["allowedChannelPlugins"] != nil {
            results.append(LintResult(
                severity: .info,
                checkId: .CFG004,
                filePath: settingsPath,
                message: "allowedChannelPlugins is configured for enterprise plugin control.",
                displayPath: "settings.json"
            ))
        }

        // CFG005: bare mode with hooks or MCP servers configured
        if let bare = json["bare"] as? Bool, bare {
            if json["hooks"] != nil || json["mcpServers"] != nil {
                results.append(LintResult(
                    severity: .warning,
                    checkId: .CFG005,
                    filePath: settingsPath,
                    message: "Bare mode is enabled but hooks or MCP servers are configured. These are ignored in bare mode.",
                    fix: "Remove hooks/mcpServers config or disable bare mode",
                    displayPath: "settings.json"
                ))
            }
        }

        // CFG006: CLAUDE_CODE_SUBPROCESS_ENV_SCRUB not set
        if envSection?["CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"] == nil {
            results.append(LintResult(
                severity: .warning,
                checkId: .CFG006,
                filePath: settingsPath,
                message: "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB is not set. Credentials may leak into subprocess environments (Bash tool, hooks, MCP servers).",
                fix: "Add CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 to settings.json env section",
                displayPath: "settings.json"
            ))
        }

        // CFG007: disableSkillShellExecution not enabled (only flag when plugins are present)
        let hasPlugins = json["enabledPlugins"] as? [String: Any] != nil
            || json["skippedPlugins"] as? [Any] != nil
        if hasPlugins && json["disableSkillShellExecution"] as? Bool != true {
            results.append(LintResult(
                severity: .info,
                checkId: .CFG007,
                filePath: settingsPath,
                message: "Skill shell execution is enabled. Installed plugins can execute arbitrary shell commands via Bash tool.",
                fix: "Add \"disableSkillShellExecution\": true to settings.json to restrict skill shell execution",
                displayPath: "settings.json"
            ))
        }

        // CFG008: allowAllClaudeAiMcps enabled
        if let allowAll = json["allowAllClaudeAiMcps"] as? Bool, allowAll {
            results.append(LintResult(
                severity: .warning,
                checkId: .CFG008,
                filePath: settingsPath,
                message: "allowAllClaudeAiMcps is enabled. All Claude.ai MCP servers are permitted without an explicit allowlist.",
                fix: "Remove allowAllClaudeAiMcps or enumerate specific MCP servers in an allowlist",
                displayPath: "settings.json"
            ))
        }

        // CFG009: sandbox enabled but no credential protection configured (CC 2.1.187)
        if let sandbox = json["sandbox"] as? [String: Any],
           let enabled = sandbox["enabled"] as? Bool, enabled {
            let cred = sandbox["credentials"] as? [String: Any]
            let fileCount = (cred?["files"] as? [Any])?.count ?? 0
            let envCount = (cred?["envVars"] as? [Any])?.count ?? 0
            if cred == nil || (fileCount == 0 && envCount == 0) {
                results.append(LintResult(
                    severity: .info,
                    checkId: .CFG009,
                    filePath: settingsPath,
                    message: "sandbox.enabled is true but sandbox.credentials is not configured. Sandboxed commands can still read credential files and secret environment variables.",
                    fix: "Add sandbox.credentials.files and/or sandbox.credentials.envVars deny entries to block secret access.",
                    displayPath: "settings.json"
                ))
            }
        }

        // CFG010: sandbox.allowAppleEvents weakens isolation (CC 2.1.181)
        if let sandbox = json["sandbox"] as? [String: Any],
           let allowAE = sandbox["allowAppleEvents"] as? Bool, allowAE {
            results.append(LintResult(
                severity: .warning,
                checkId: .CFG010,
                filePath: settingsPath,
                message: "sandbox.allowAppleEvents is enabled. Sandboxed commands can send Apple Events to launch or control other apps, weakening process isolation.",
                fix: "Set sandbox.allowAppleEvents to false unless a specific workflow requires it.",
                displayPath: "settings.json"
            ))
        }

        // CFG011: respondToBashCommands disabled while hooks are configured (CC 2.1.186)
        if let respond = json["respondToBashCommands"] as? Bool, !respond, json["hooks"] != nil {
            results.append(LintResult(
                severity: .info,
                checkId: .CFG011,
                filePath: settingsPath,
                message: "respondToBashCommands is false, so \"!\" bash commands are added to context without a model response. Confirm hook-driven automation still behaves as intended.",
                displayPath: "settings.json"
            ))
        }

        return results
    }
}

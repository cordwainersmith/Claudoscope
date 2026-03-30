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

        return results
    }
}

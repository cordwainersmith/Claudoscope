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

        let sandbox = json["sandbox"] as? [String: Any]
        let sandboxEnabled = (sandbox?["enabled"] as? Bool) == true
        let network = sandbox?["network"] as? [String: Any]

        // CFG013: filesystem isolation switched off (CC 2.1.216)
        if (sandbox?["filesystem"] as? [String: Any])?["disabled"] as? Bool == true {
            results.append(LintResult(
                severity: .warning,
                checkId: .CFG013,
                filePath: settingsPath,
                message: "sandbox.filesystem.disabled is true. Sandboxed commands get full filesystem access; only network egress is still controlled.",
                fix: "Remove sandbox.filesystem.disabled unless a specific tool cannot run under filesystem isolation.",
                displayPath: "settings.json"
            ))
        }

        // CFG014: sandbox without a strict network allowlist (CC 2.1.219)
        if sandboxEnabled, (network?["strictAllowlist"] as? Bool) != true {
            results.append(LintResult(
                severity: .info,
                checkId: .CFG014,
                filePath: settingsPath,
                message: "sandbox.enabled is true without sandbox.network.strictAllowlist. A command reaching a non-allowlisted host prompts for approval instead of being denied.",
                fix: "Set sandbox.network.strictAllowlist to true to deny unlisted hosts outright.",
                displayPath: "settings.json"
            ))
        }

        // CFG015: credential masking needs TLS termination to substitute on egress
        // (CC 2.1.221/.224). Without it the mask never applies and the sentinel value
        // is what leaves the machine.
        if let cred = sandbox?["credentials"] as? [String: Any] {
            let entries = ((cred["files"] as? [[String: Any]]) ?? []) + ((cred["envVars"] as? [[String: Any]]) ?? [])
            let masks = entries.filter { ($0["mode"] as? String) == "mask" }
            if !masks.isEmpty, (network?["tlsTerminate"] as? Bool) != true {
                results.append(LintResult(
                    severity: .warning,
                    checkId: .CFG015,
                    filePath: settingsPath,
                    message: "\(masks.count) sandbox credential entr\(masks.count == 1 ? "y uses" : "ies use") mode \"mask\" but sandbox.network.tlsTerminate is not enabled, so the real value is never substituted on egress.",
                    fix: "Enable sandbox.network.tlsTerminate, or switch those entries to mode \"deny\".",
                    displayPath: "settings.json"
                ))
            }
        }

        // CFG018: cross-session messages auto-accepted into a bypassed session
        // (CC 2.1.224). Claude Code holds them for approval by default in that
        // combination; "accept" opts out of the one guard on the path.
        let defaultMode = (json["permissions"] as? [String: Any])?["defaultMode"] as? String
        if json["crossSessionInbound"] as? String == "accept", defaultMode == "bypassPermissions" {
            results.append(LintResult(
                severity: .warning,
                checkId: .CFG018,
                filePath: settingsPath,
                message: "crossSessionInbound is \"accept\" while permissions.defaultMode is \"bypassPermissions\". Messages from your other sessions are delivered unreviewed to a session that approves every tool call.",
                fix: "Set crossSessionInbound to \"hold\" so inbound messages are approved first.",
                displayPath: "settings.json"
            ))
        }

        results += lintProjectScopedSettings(projectRoot: projectRoot)

        return results
    }

    /// Rules for keys that Claude Code reads only from user, managed, or `--settings`
    /// scope. Setting them in a repo is not an error the CLI reports, it just does
    /// nothing, which reads as working config to whoever added it.
    private func lintProjectScopedSettings(projectRoot: URL?) -> [LintResult] {
        guard let projectRoot else { return [] }
        var results: [LintResult] = []

        for name in ["settings.json", "settings.local.json"] {
            let url = projectRoot.appendingPathComponent(".claude").appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let displayPath = ".claude/\(name)"

            // CFG016: sandbox binary overrides ignored outside user scope (CC 2.1.232)
            if let sandbox = json["sandbox"] as? [String: Any] {
                let overrides = ["bwrapPath", "socatPath", "ripgrep"].filter { sandbox[$0] != nil }
                if !overrides.isEmpty {
                    results.append(LintResult(
                        severity: .warning,
                        checkId: .CFG016,
                        filePath: url.path,
                        message: "sandbox.\(overrides.joined(separator: ", sandbox.")) set in project settings. Claude Code 2.1.232 honors sandbox binary overrides only from user, managed, and --settings scope, so this has no effect.",
                        fix: "Move the override to ~/.claude/settings.json, or remove it.",
                        displayPath: displayPath
                    ))
                }
            }

            // CFG017: Remote Control auto-start ignored from repo-local scope (CC 2.1.222)
            if json["remoteControlAtStartup"] as? Bool == true {
                results.append(LintResult(
                    severity: .warning,
                    checkId: .CFG017,
                    filePath: url.path,
                    message: "remoteControlAtStartup is enabled in project settings. Since Claude Code 2.1.222 repo-local settings can only turn Remote Control off, never on.",
                    fix: "Enable Remote Control at user scope via /config, or remove the key.",
                    displayPath: displayPath
                ))
            }
        }

        return results
    }
}

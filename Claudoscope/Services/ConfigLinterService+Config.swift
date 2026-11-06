import Foundation

extension ConfigLinterService {

    // MARK: - Config Health Checks

    func lintConfig(globalClaudeDir: URL, projectRoot: URL?, now: Date = Date()) -> [LintResult] {
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

        // CFG021: output caps outside the range Claude Code accepts (CC 2.1.253)
        for key in ["bashOutputMaxChars", "taskOutputMaxChars"] {
            guard let raw = json[key] as? Int else { continue }
            guard raw < Self.outputCharCapRange.lowerBound || raw > Self.outputCharCapRange.upperBound else { continue }
            let clamped = min(max(raw, Self.outputCharCapRange.lowerBound), Self.outputCharCapRange.upperBound)
            results.append(LintResult(
                severity: .info,
                checkId: .CFG021,
                filePath: settingsPath,
                message: "\(key) is \(raw); Claude Code clamps it to \(clamped).",
                fix: "Set \(key) between \(Self.outputCharCapRange.lowerBound) and \(Self.outputCharCapRange.upperBound), or remove the key.",
                displayPath: "settings.json"
            ))
        }

        results += lintBashAllowRules(json: json, filePath: settingsPath, displayPath: "settings.json")
        results += lintBooleanAttribution(json: json, filePath: settingsPath, displayPath: "settings.json")
        results += lintNestedUserNamespaces(json: json, filePath: settingsPath, displayPath: "settings.json")
        results += lintDisableCompactFalsy(json: json, filePath: settingsPath, displayPath: "settings.json")
        results += lintOpus48FastMode(json: json, filePath: settingsPath, displayPath: "settings.json", now: now)

        // CFG026: model policy keys documented as managed settings (CC 2.1.283/2.1.285)
        for key in ["deniedModels", "availableModelsMatch", "allowedProviders"] where json[key] != nil {
            results.append(LintResult(
                severity: .info,
                checkId: .CFG026,
                filePath: settingsPath,
                message: "\(key) is set in user settings. Claude Code documents it as a managed setting, so it may not be enforced from here.",
                fix: "Deploy \(key) through managed settings, or remove it from ~/.claude/settings.json.",
                displayPath: "settings.json"
            ))
        }

        results += lintManagedMcpServers()
        results += lintProjectScopedSettings(projectRoot: projectRoot)

        return results
    }

    /// Range Claude Code clamps `bashOutputMaxChars` / `taskOutputMaxChars` into.
    static let outputCharCapRange = 4000...128000

    /// CFG020: a Bash allow rule whose wildcard is not the final segment. Runs
    /// against every scope that can hold a permissions block, because the allow
    /// list usually lives in the repo rather than user settings.
    private func lintBashAllowRules(json: [String: Any], filePath: String, displayPath: String) -> [LintResult] {
        let allow = (json["permissions"] as? [String: Any])?["allow"] as? [String] ?? []
        return allow.compactMap { rule in
            guard let body = Self.bashRuleBody(rule), Self.hasNonTerminalWildcard(body) else { return nil }
            let prefix = Self.bashRulePrefix(body)
            return LintResult(
                severity: .warning,
                checkId: .CFG020,
                filePath: filePath,
                message: "permissions.allow rule \"\(rule)\" has a wildcard before its last segment. Bash rules match a prefix, so everything after the \"*\" is ignored and this allows any command starting \"\(prefix)\".",
                fix: "Use a terminal prefix such as Bash(\(prefix):*), or enumerate the subcommands you mean to allow.",
                displayPath: displayPath
            )
        }
    }

    /// CFG022: `"attribution": false` (CC 2.1.281). Older CLIs skip a settings
    /// file holding the boolean, so shared files should use the object form.
    private func lintBooleanAttribution(json: [String: Any], filePath: String, displayPath: String) -> [LintResult] {
        guard json["attribution"] as? Bool == false else { return [] }
        return [LintResult(
            severity: .warning,
            checkId: .CFG022,
            filePath: filePath,
            message: "\(displayPath) sets \"attribution\": false. Claude Code older than 2.1.281 skips a settings file holding the boolean form.",
            fix: "Use the object form {\"commit\": \"\", \"pr\": \"\"}, which every version reads.",
            displayPath: displayPath
        )]
    }

    /// CFG027: `sandbox.allowNestedUserNamespaces` (CC 2.1.305) lets sandboxed
    /// commands get around the sandbox's file protections.
    private func lintNestedUserNamespaces(json: [String: Any], filePath: String, displayPath: String) -> [LintResult] {
        guard (json["sandbox"] as? [String: Any])?["allowNestedUserNamespaces"] as? Bool == true else { return [] }
        return [LintResult(
            severity: .warning,
            checkId: .CFG027,
            filePath: filePath,
            message: "\(displayPath) sets sandbox.allowNestedUserNamespaces. Sandboxed commands can create user namespaces, which lets them get around the sandbox's file protections.",
            fix: "Remove it unless a tool such as Chromium or rootless podman needs it.",
            displayPath: displayPath
        )]
    }

    /// CFG029: since CC 2.1.311 `DISABLE_COMPACT` in settings can only turn
    /// compaction off; a falsy value does not turn it back on.
    private func lintDisableCompactFalsy(json: [String: Any], filePath: String, displayPath: String) -> [LintResult] {
        guard let env = json["env"] as? [String: Any], let value = env["DISABLE_COMPACT"] else { return [] }
        let text = ((value as? String) ?? (value as? NSNumber)?.stringValue ?? "").lowercased()
            .trimmingCharacters(in: .whitespaces)
        guard ["", "0", "false", "no", "off"].contains(text) else { return [] }
        return [LintResult(
            severity: .info,
            checkId: .CFG029,
            filePath: filePath,
            message: "\(displayPath) env sets DISABLE_COMPACT to \"\(text)\". Since Claude Code 2.1.311 settings can only turn compaction off, so this does not re-enable it.",
            fix: "Remove DISABLE_COMPACT from env.",
            displayPath: displayPath
        )]
    }

    static let opus48FastModeRemoval: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = 30
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    /// CFG030: fast mode with Opus 4.8 configured. Deprecated 2026-10-30,
    /// removed 2026-11-30 (CC 2.1.316); after removal the requests error out.
    private func lintOpus48FastMode(json: [String: Any], filePath: String, displayPath: String, now: Date) -> [LintResult] {
        guard json["fastMode"] as? Bool == true else { return [] }
        let env = json["env"] as? [String: Any] ?? [:]
        let models = [json["model"], env["ANTHROPIC_MODEL"], env["ANTHROPIC_DEFAULT_OPUS_MODEL"]]
            .compactMap { $0 as? String }
        guard let model = models.first(where: { $0.lowercased().contains("opus-4-8") }) else { return [] }
        let removed = now >= Self.opus48FastModeRemoval
        return [LintResult(
            severity: removed ? .error : .warning,
            checkId: .CFG030,
            filePath: filePath,
            message: removed
                ? "\(displayPath) turns on fast mode with \(model). Fast mode on Opus 4.8 was removed on November 30, 2026; these requests now fail."
                : "\(displayPath) turns on fast mode with \(model). Fast mode on Opus 4.8 is removed on November 30, 2026, after which these requests fail instead of falling back.",
            fix: "Switch to Opus 5.5 to keep fast mode, or turn fast mode off.",
            displayPath: displayPath
        )]
    }

    /// Keys Claude Code ignores in project settings: `CLAUDE_CODE_DISABLE_ATTACHMENTS`
    /// and turning on Claude in Chrome (2.1.290), screen reader mode (2.1.307).
    static func projectIgnoredUserScopeKeys(_ json: [String: Any]) -> [String] {
        var keys: [String] = []
        if json["claudeInChromeDefaultEnabled"] as? Bool == true { keys.append("claudeInChromeDefaultEnabled") }
        if json["axScreenReader"] != nil { keys.append("axScreenReader") }
        if let env = json["env"] as? [String: Any] {
            for key in ["CLAUDE_CODE_DISABLE_ATTACHMENTS", "CLAUDE_AX_SCREEN_READER"] where env[key] != nil {
                keys.append("env.\(key)")
            }
        }
        return keys
    }

    /// CFG031: permission rules written as `mcp__<name>` that used to reach
    /// servers whose normalized name merely starts with `<name>` (CC 2.1.299).
    func lintMcpPermissionRules(globalClaudeDir: URL, projectRoot: URL?, mcpServerNames: Set<String>) -> [LintResult] {
        var files: [(url: URL, display: String)] = [(globalClaudeDir.appendingPathComponent("settings.json"), "settings.json")]
        if let projectRoot {
            for name in ["settings.json", "settings.local.json"] {
                files.append((projectRoot.appendingPathComponent(".claude").appendingPathComponent(name), ".claude/\(name)"))
            }
        }
        var results: [LintResult] = []
        for file in files {
            guard let data = try? Data(contentsOf: file.url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let permissions = json["permissions"] as? [String: Any] else { continue }
            let rules = ["allow", "deny", "ask"].flatMap { permissions[$0] as? [String] ?? [] }
            for (rule, servers) in Self.staleMcpPrefixRules(rules, servers: Array(mcpServerNames)) {
                results.append(LintResult(
                    severity: .warning,
                    checkId: .CFG031,
                    filePath: file.url.path,
                    message: "Permission rule \"\(rule)\" in \(file.display) no longer covers \(servers.joined(separator: ", ")). Since Claude Code 2.1.299 it reaches only a server named exactly that.",
                    fix: servers.map { "mcp__\($0)__*" }.joined(separator: ", "),
                    displayPath: file.display
                ))
            }
        }
        return results
    }

    /// Claude Code normalizes server names to `[A-Za-z0-9_-]`, other characters
    /// becoming `_`.
    static func normalizedMcpName(_ name: String) -> String {
        String(name.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "_" })
    }

    /// Rules (or agent `tools:` entries) of the bare form `mcp__<seg>` or
    /// `mcp__<seg>__*` where no server is named exactly `<seg>` but one or more
    /// start with `<seg>_`. Returns each such rule with the servers it lost.
    static func staleMcpPrefixRules(_ rules: [String], servers: [String]) -> [(rule: String, servers: [String])] {
        let names = servers.map(normalizedMcpName)
        var out: [(String, [String])] = []
        for rule in rules {
            guard rule.hasPrefix("mcp__") else { continue }
            var seg = String(rule.dropFirst("mcp__".count))
            if seg.hasSuffix("__*") { seg = String(seg.dropLast(3)) }
            guard !seg.isEmpty, !seg.contains("__"), !seg.contains("("), !seg.contains("*") else { continue }
            guard !names.contains(seg) else { continue }
            let lost = names.filter { $0.hasPrefix(seg + "_") }.sorted()
            if !lost.isEmpty { out.append((rule, lost)) }
        }
        return out
    }

    /// Env keys that turn on or route OpenTelemetry export. Claude Code ignores
    /// them in project and local settings since 2.1.282.
    static func isProjectIgnoredTelemetryKey(_ key: String, value: Any) -> Bool {
        if key == "CLAUDE_CODE_ENABLE_TELEMETRY" {
            let text = (value as? String)?.lowercased() ?? (value as? NSNumber)?.stringValue ?? ""
            return text == "1" || text == "true"
        }
        if ["OTEL_METRICS_EXPORTER", "OTEL_LOGS_EXPORTER", "OTEL_TRACES_EXPORTER"].contains(key) {
            return true
        }
        if key.hasPrefix("OTEL_EXPORTER_OTLP_"), key.hasSuffix("ENDPOINT") {
            return true
        }
        return key.hasPrefix("OTEL_LOG_")
    }

    /// CFG024 / CFG025 over the merged MCP inventory.
    func lintMcpServerEntries(_ servers: [McpServerEntry]) -> [LintResult] {
        var results: [LintResult] = []
        for server in servers {
            let location = "MCP: \(server.name)"
            // CFG024: reserved name (CC 2.1.282). claude-ai was un-reserved in 2.1.283.
            if server.name == "anthropic-skills" {
                results.append(LintResult(
                    severity: .info,
                    checkId: .CFG024,
                    filePath: location,
                    message: "MCP server \"anthropic-skills\" (\(server.level ?? "unknown") scope) uses a name Claude Code reserves; its skills and prompts are not listed.",
                    fix: "Rename the server.",
                    displayPath: location
                ))
            }
            // CFG025: SDK servers are skipped outside the Agent SDK (CC 2.1.274).
            if server.type?.lowercased() == "sdk" {
                results.append(LintResult(
                    severity: .warning,
                    checkId: .CFG025,
                    filePath: location,
                    message: "MCP server \"\(server.name)\" (\(server.level ?? "unknown") scope) has type \"sdk\". Claude Code skips SDK servers in config files, so it never starts.",
                    fix: "Remove the entry, or define \"\(server.name)\" as a stdio or http server.",
                    displayPath: location
                ))
            }
        }
        return results
    }

    /// CFG019: managed-scope MCP servers must be http or sse. Claude Code
    /// silently skips a stdio entry here, so the admin believes a server is
    /// deployed fleet-wide when it is not running anywhere.
    private func lintManagedMcpServers() -> [LintResult] {
        guard let data = try? Data(contentsOf: managedSettingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["managedMcpServers"] as? [String: Any]
        else { return [] }

        var results: [LintResult] = []
        for (name, value) in servers.sorted(by: { $0.key < $1.key }) {
            guard let config = value as? [String: Any] else { continue }
            let hasCommand = (config["command"] as? String)?.isEmpty == false
            let type = (config["type"] as? String)?.lowercased()
            let hasRemote = config["url"] != nil || type == "http" || type == "sse"
            guard hasCommand || type == "stdio", !hasRemote else { continue }
            results.append(LintResult(
                severity: .error,
                checkId: .CFG019,
                filePath: managedSettingsURL.path,
                message: "managedMcpServers entry \"\(name)\" defines a stdio command. Claude Code accepts only http and sse servers in managed scope and silently skips this one.",
                fix: "Convert \"\(name)\" to an http or sse server, or deploy it through .mcp.json instead.",
                displayPath: "managed-settings.json"
            ))
        }
        return results
    }

    /// Returns the inner pattern of a `Bash(...)` permission rule, or nil for
    /// any other tool.
    static func bashRuleBody(_ rule: String) -> String? {
        guard rule.hasPrefix("Bash("), rule.hasSuffix(")") else { return nil }
        return String(rule.dropFirst(5).dropLast())
    }

    /// True when a `*` appears before the end of the pattern and is followed by
    /// something other than the `:*` suffix form, i.e. the tail is dead text.
    static func hasNonTerminalWildcard(_ body: String) -> Bool {
        guard let star = body.range(of: "*") else { return false }
        let tail = body[star.upperBound...]
        if tail.isEmpty { return false }
        // "git push:*" and "npm run *" are terminal; "git * main" is not.
        return tail.contains { !$0.isWhitespace }
    }

    /// The literal prefix a Bash rule actually enforces: everything before the
    /// first wildcard.
    static func bashRulePrefix(_ body: String) -> String {
        guard let star = body.range(of: "*") else { return body }
        return String(body[body.startIndex..<star.lowerBound])
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
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

            results += lintBashAllowRules(json: json, filePath: url.path, displayPath: displayPath)
            results += lintNestedUserNamespaces(json: json, filePath: url.path, displayPath: displayPath)
            results += lintDisableCompactFalsy(json: json, filePath: url.path, displayPath: displayPath)

            // CFG028: keys Claude Code reads only from user/managed scope (CC 2.1.290, 2.1.307)
            let ignored = Self.projectIgnoredUserScopeKeys(json)
            if !ignored.isEmpty {
                results.append(LintResult(
                    severity: .warning,
                    checkId: .CFG028,
                    filePath: url.path,
                    message: "\(displayPath) sets \(ignored.joined(separator: ", ")). Claude Code reads these only from user or managed settings, so they do nothing here.",
                    fix: "Move them to ~/.claude/settings.json, or remove them.",
                    displayPath: displayPath
                ))
            }

            if name == "settings.json" {
                results += lintBooleanAttribution(json: json, filePath: url.path, displayPath: displayPath)
            }

            // CFG023: telemetry export env ignored outside user/managed scope (CC 2.1.282)
            if let env = json["env"] as? [String: Any] {
                let keys = env.keys.sorted().filter { Self.isProjectIgnoredTelemetryKey($0, value: env[$0]!) }
                if !keys.isEmpty {
                    results.append(LintResult(
                        severity: .warning,
                        checkId: .CFG023,
                        filePath: url.path,
                        message: "\(displayPath) env sets \(keys.joined(separator: ", ")). Claude Code 2.1.282+ ignores telemetry export settings from project scope.",
                        fix: "Move telemetry settings to ~/.claude/settings.json or managed settings, or remove them.",
                        displayPath: displayPath
                    ))
                }
            }

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

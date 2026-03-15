import Foundation

/// Reads Claude Code configuration data from ~/.claude/ filesystem.
/// Handles settings.json (hooks), claude.json (MCPs), commands, skills, and memory files.
actor ConfigService {
    private let claudeDir: URL
    private let fm = FileManager.default

    /// Known hook event names in Claude Code.
    static let hookEventNames = [
        "PreToolUse",
        "PostToolUse",
        "SessionStart",
        "Stop",
        "UserPromptSubmit",
        "Notification"
    ]

    init(claudeDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")) {
        self.claudeDir = claudeDir
    }

    // MARK: - JSON Reading

    private func readJSON(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    // MARK: - Hooks

    func loadHooks() -> [HookEventGroup] {
        guard let settings = readJSON(at: claudeDir.appendingPathComponent("settings.json")),
              let hooksDict = settings["hooks"] as? [String: Any] else {
            return []
        }

        var groups: [HookEventGroup] = []

        for eventName in Self.hookEventNames {
            guard let rulesArray = hooksDict[eventName] as? [[String: Any]] else {
                continue
            }

            var rules: [HookRule] = []

            for ruleDict in rulesArray {
                let matcher = ruleDict["matcher"] as? String ?? "*"
                var hookCommands: [HookCommand] = []

                if let hooksArray = ruleDict["hooks"] as? [[String: Any]] {
                    for hookDict in hooksArray {
                        let command = hookDict["command"] as? String ?? ""
                        let type = hookDict["type"] as? String
                        let timeout = hookDict["timeout"] as? Int
                        hookCommands.append(HookCommand(
                            type: type,
                            command: command,
                            timeout: timeout
                        ))
                    }
                }

                if !hookCommands.isEmpty {
                    rules.append(HookRule(
                        id: UUID().uuidString,
                        matcher: matcher,
                        hooks: hookCommands
                    ))
                }
            }

            if !rules.isEmpty {
                groups.append(HookEventGroup(event: eventName, rules: rules))
            }
        }

        return groups
    }

    // MARK: - MCP Servers

    /// MCP servers are stored in ~/.claude/claude.json under "mcpServers".
    func loadMcpServers() -> [McpServerEntry] {
        var merged: [String: [String: Any]] = [:]

        // 1. claude.json (primary source)
        if let claudeJson = readJSON(at: claudeDir.appendingPathComponent("claude.json")),
           let servers = claudeJson["mcpServers"] as? [String: [String: Any]] {
            for (name, config) in servers {
                merged[name] = config
            }
        }

        // 2. Also check settings.json mcpServers (some setups use this)
        if let settings = readJSON(at: claudeDir.appendingPathComponent("settings.json")),
           let servers = settings["mcpServers"] as? [String: [String: Any]] {
            for (name, config) in servers {
                if merged[name] == nil {
                    merged[name] = config
                }
            }
        }

        var entries: [McpServerEntry] = []

        for (name, serverDict) in merged {
            let command = serverDict["command"] as? String
            let args = serverDict["args"] as? [String] ?? []
            let url = serverDict["url"] as? String
            let env = serverDict["env"] as? [String: String] ?? [:]

            entries.append(McpServerEntry(
                name: name,
                command: command,
                args: args,
                url: url,
                env: env,
                level: "global"
            ))
        }

        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return entries
    }

    // MARK: - Commands

    /// Scan global commands from ~/.claude/commands/ AND plugin commands.
    func loadCommands() -> [CommandEntry] {
        var entries: [CommandEntry] = []

        // 1. Global commands from ~/.claude/commands/
        let commandsDir = claudeDir.appendingPathComponent("commands")
        if let fileNames = try? fm.contentsOfDirectory(atPath: commandsDir.path) {
            for fileName in fileNames where fileName.hasSuffix(".md") {
                if let entry = readCommandFile(
                    url: commandsDir.appendingPathComponent(fileName),
                    name: String(fileName.dropLast(3))
                ) {
                    entries.append(entry)
                }
            }
        }

        // 2. Plugin commands from ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/commands/
        for (plugin, versionDir) in latestPluginVersionDirs() {
            let cmdsDir = versionDir.appendingPathComponent("commands")
            if let cmdFiles = try? fm.contentsOfDirectory(atPath: cmdsDir.path) {
                for cmdFile in cmdFiles where cmdFile.hasSuffix(".md") {
                    let cmdName = String(cmdFile.dropLast(3))
                    if let entry = readCommandFile(
                        url: cmdsDir.appendingPathComponent(cmdFile),
                        name: cmdName,
                        pluginName: plugin
                    ) {
                        entries.append(entry)
                    }
                }
            }
        }

        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return entries
    }

    // MARK: - Skills

    /// Scan skills from plugins and ~/.claude/skills/.
    func loadSkills() -> [SkillEntry] {
        var entries: [SkillEntry] = []

        // 1. Plugin skills from ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/skills/
        for (plugin, versionDir) in latestPluginVersionDirs() {
            let skillsDir = versionDir.appendingPathComponent("skills")
            if let skillDirs = try? fm.contentsOfDirectory(atPath: skillsDir.path) {
                for skillDir in skillDirs {
                    let skillFile = skillsDir
                        .appendingPathComponent(skillDir)
                        .appendingPathComponent("SKILL.md")
                    if let entry = readSkillFile(url: skillFile, name: skillDir, pluginName: plugin) {
                        entries.append(entry)
                    }
                }
            }
        }

        // 2. Global skills from ~/.claude/skills/
        let globalSkillsDir = claudeDir.appendingPathComponent("skills")
        if let skillDirs = try? fm.contentsOfDirectory(atPath: globalSkillsDir.path) {
            for skillDir in skillDirs {
                let skillFile = globalSkillsDir
                    .appendingPathComponent(skillDir)
                    .appendingPathComponent("SKILL.md")
                if let entry = readSkillFile(url: skillFile, name: skillDir) {
                    entries.append(entry)
                }
            }
        }

        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return entries
    }

    /// Resolve latest plugin version directories.
    private func latestPluginVersionDirs() -> [(plugin: String, versionDir: URL)] {
        let cacheDir = claudeDir
            .appendingPathComponent("plugins")
            .appendingPathComponent("cache")

        var results: [(String, URL)] = []

        guard let marketplaces = try? fm.contentsOfDirectory(atPath: cacheDir.path) else {
            return results
        }

        for marketplace in marketplaces {
            let marketplaceDir = cacheDir.appendingPathComponent(marketplace)
            guard let plugins = try? fm.contentsOfDirectory(atPath: marketplaceDir.path) else { continue }

            for plugin in plugins {
                let pluginDir = marketplaceDir.appendingPathComponent(plugin)
                guard let versions = try? fm.contentsOfDirectory(atPath: pluginDir.path) else { continue }
                guard let latestVersion = versions.sorted().last else { continue }
                results.append((plugin, pluginDir.appendingPathComponent(latestVersion)))
            }
        }

        return results
    }

    private func readSkillFile(url: URL, name: String, pluginName: String? = nil) -> SkillEntry? {
        guard fm.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let sizeBytes = (attrs?[.size] as? Int) ?? data.count
        let parsed = parseSkillContent(content)

        return SkillEntry(
            name: parsed.name ?? name,
            displayName: pluginName != nil ? "\(parsed.name ?? name) (\(pluginName!))" : (parsed.name ?? name),
            description: parsed.description,
            metadata: parsed.metadata,
            body: parsed.body,
            sizeBytes: sizeBytes
        )
    }

    /// Parse a SKILL.md file, extracting frontmatter metadata and body content.
    private func parseSkillContent(_ content: String) -> (name: String?, description: String?, metadata: [String: String], body: String) {
        let lines = content.components(separatedBy: "\n")
        var name: String?
        var description: String?
        var metadata: [String: String] = [:]
        var bodyStartIndex = 0
        var inFrontmatter = true
        var currentKey: String?
        var currentValue: String?

        func flushCurrentKey() {
            if let key = currentKey, let value = currentValue {
                let trimmedValue = value.trimmingCharacters(in: .whitespaces)
                switch key {
                case "name": name = trimmedValue
                case "description": description = trimmedValue
                default: metadata[key] = trimmedValue
                }
            }
            currentKey = nil
            currentValue = nil
        }

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            guard inFrontmatter else { break }

            // End-of-frontmatter marker
            if trimmed == "---" {
                flushCurrentKey()
                bodyStartIndex = index + 1
                inFrontmatter = false
                continue
            }

            // Empty line ends frontmatter
            if trimmed.isEmpty {
                flushCurrentKey()
                bodyStartIndex = index + 1
                inFrontmatter = false
                continue
            }

            // Check for "key: value" pattern (key must start at column 0 or be a simple word)
            if let colonRange = trimmed.range(of: ":"),
               colonRange.lowerBound != trimmed.startIndex {
                let key = String(trimmed[trimmed.startIndex..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                // Only treat as frontmatter if key is a simple identifier (no spaces, no markdown)
                if !key.isEmpty && key.range(of: "^[a-zA-Z_][a-zA-Z0-9_-]*$", options: .regularExpression) != nil {
                    flushCurrentKey()
                    let value = String(trimmed[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    currentKey = key
                    currentValue = value
                    bodyStartIndex = index + 1
                    continue
                }
            }

            // Indented continuation of previous value (for multi-line args, etc.)
            if currentKey != nil && (line.hasPrefix("  ") || line.hasPrefix("\t")) {
                currentValue = (currentValue ?? "") + "\n" + trimmed
                bodyStartIndex = index + 1
                continue
            }

            // Line doesn't match frontmatter pattern, start body here
            flushCurrentKey()
            inFrontmatter = false
            bodyStartIndex = index
        }

        flushCurrentKey()

        let bodyLines = Array(lines[bodyStartIndex...])
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        return (name, description, metadata, body)
    }

    private func readCommandFile(url: URL, name: String, pluginName: String? = nil) -> CommandEntry? {
        guard fm.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let sizeBytes = (attrs?[.size] as? Int) ?? data.count
        let description = extractDescription(from: content)

        let displayName = pluginName != nil ? "\(name) (\(pluginName!))" : name

        return CommandEntry(
            name: displayName,
            description: description,
            content: content,
            sizeBytes: sizeBytes
        )
    }

    // MARK: - Memory Files

    func loadMemoryFiles(projectId: String?) -> [MemoryFile] {
        var files: [MemoryFile] = []

        // 1. Global CLAUDE.md
        files.append(makeMemoryFile(
            id: "global",
            label: "CLAUDE.md",
            sublabel: "global",
            url: claudeDir.appendingPathComponent("CLAUDE.md")
        ))

        // 2. Project CLAUDE.md
        if let projectId, let decodedPath = decodeProjectPath(projectId) {
            files.append(makeMemoryFile(
                id: "project",
                label: "CLAUDE.md",
                sublabel: "project",
                url: URL(fileURLWithPath: decodedPath).appendingPathComponent("CLAUDE.md")
            ))
        }

        // 3. MEMORY.md
        if let projectId {
            let projectDir = claudeDir
                .appendingPathComponent("projects")
                .appendingPathComponent(projectId)
            let memorySubdir = projectDir.appendingPathComponent("memory").appendingPathComponent("MEMORY.md")
            let memoryDirect = projectDir.appendingPathComponent("MEMORY.md")

            let memoryURL = fm.fileExists(atPath: memorySubdir.path) ? memorySubdir : memoryDirect
            files.append(makeMemoryFile(
                id: "memory",
                label: "MEMORY.md",
                sublabel: "auto-memory",
                url: memoryURL
            ))
        }

        return files
    }

    // MARK: - Extended Config

    func loadExtendedConfig() -> ExtendedConfig {
        let settings = readJSON(at: claudeDir.appendingPathComponent("settings.json")) ?? [:]

        // Sandbox
        let sandbox: SandboxConfig?
        if let sandboxDict = settings["sandbox"] as? [String: Any] {
            let cmds = sandboxDict["unsandboxedCommands"] as? [String] ?? []
            let weaker = sandboxDict["enableWeakerNestedSandbox"] as? Bool ?? false
            sandbox = SandboxConfig(unsandboxedCommands: cmds, enableWeakerNestedSandbox: weaker)
        } else {
            sandbox = nil
        }

        let yolo = settings["skipDangerousModePermissionPrompt"] as? Bool ?? false

        // Attribution
        let attribution: AttributionConfig?
        if let attrDict = settings["attribution"] as? [String: Any] {
            let commit = attrDict["commitMessage"] as? String
            let pr = attrDict["pullRequestDescription"] as? String
            let deprecated = settings["includeCoAuthoredBy"] != nil
            attribution = AttributionConfig(commitTemplate: commit, prTemplate: pr, hasDeprecatedCoAuthoredBy: deprecated)
        } else if settings["includeCoAuthoredBy"] != nil {
            attribution = AttributionConfig(commitTemplate: nil, prTemplate: nil, hasDeprecatedCoAuthoredBy: true)
        } else {
            attribution = nil
        }

        // Plugins
        var plugins: [PluginInfo] = []
        if let enabledDict = settings["enabledPlugins"] as? [String: Any] {
            for (key, value) in enabledDict.sorted(by: { $0.key < $1.key }) {
                let enabled = (value as? NSNumber)?.boolValue ?? true
                let parts = key.split(separator: "@", maxSplits: 1)
                let name = String(parts.first ?? Substring(key))
                let marketplace = parts.count > 1 ? String(parts[1]) : nil
                plugins.append(PluginInfo(fullName: key, name: name, marketplace: marketplace, enabled: enabled))
            }
        }
        // Also include skipped plugins as disabled
        if let skipped = settings["skippedPlugins"] as? [String] {
            for key in skipped where !plugins.contains(where: { $0.fullName == key }) {
                let parts = key.split(separator: "@", maxSplits: 1)
                let name = String(parts.first ?? Substring(key))
                let marketplace = parts.count > 1 ? String(parts[1]) : nil
                plugins.append(PluginInfo(fullName: key, name: name, marketplace: marketplace, enabled: false))
            }
        }

        // Marketplaces
        var marketplaces: [MarketplaceSource] = []
        if let extraDict = settings["extraKnownMarketplaces"] as? [String: Any] {
            for (name, value) in extraDict.sorted(by: { $0.key < $1.key }) {
                if let info = value as? [String: Any] {
                    let sourceType = info["type"] as? String ?? "unknown"
                    let detail = (info["repo"] as? String)
                        ?? (info["package"] as? String)
                        ?? (info["directory"] as? String)
                        ?? ""
                    marketplaces.append(MarketplaceSource(name: name, sourceType: sourceType, detail: detail))
                } else if let str = value as? String {
                    marketplaces.append(MarketplaceSource(name: name, sourceType: "url", detail: str))
                }
            }
        }

        // Profile from ~/.claude.json
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let profile: ClaudeProfile?
        if let profileJson = readJSON(at: homeDir.appendingPathComponent(".claude.json")) {
            let email: String?
            if let oauth = profileJson["oauthAccount"] as? [String: Any],
               let rawEmail = oauth["email"] as? String {
                email = maskEmail(rawEmail)
            } else {
                email = nil
            }
            let orgRole: String?
            if let oauth = profileJson["oauthAccount"] as? [String: Any] {
                orgRole = oauth["orgRole"] as? String
            } else {
                orgRole = nil
            }

            profile = ClaudeProfile(
                numStartups: profileJson["numStartups"] as? Int,
                theme: profileJson["theme"] as? String,
                autoUpdatesChannel: profileJson["autoUpdatesChannel"] as? String,
                hasCompletedOnboarding: profileJson["hasCompletedOnboarding"] as? Bool,
                lastOnboardingVersion: profileJson["lastOnboardingVersion"] as? String,
                lastReleaseNotesSeen: profileJson["lastReleaseNotesSeen"] as? String,
                shiftEnterKeyBindingInstalled: profileJson["shiftEnterKeyBindingInstalled"] as? Bool,
                maskedEmail: email,
                orgRole: orgRole
            )
        } else {
            profile = nil
        }

        return ExtendedConfig(
            sandbox: sandbox,
            skipDangerousModePermissionPrompt: yolo,
            attribution: attribution,
            plugins: plugins,
            marketplaces: marketplaces,
            profile: profile
        )
    }

    private func maskEmail(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return "***" }
        let local = parts[0]
        let domain = parts[1]
        let prefix = local.prefix(2)
        return "\(prefix)***@\(domain)"
    }

    // MARK: - Private Helpers

    private func extractDescription(from content: String) -> String? {
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("---") { continue }
            if trimmed.hasPrefix("# ") {
                let desc = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                return desc.isEmpty ? nil : desc
            }
            return trimmed
        }
        return nil
    }

    private func makeMemoryFile(id: String, label: String, sublabel: String, url: URL) -> MemoryFile {
        let path = url.path

        guard fm.fileExists(atPath: path),
              let attrs = try? fm.attributesOfItem(atPath: path),
              let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            return MemoryFile(id: id, label: label, sublabel: sublabel, path: path, content: nil, sizeBytes: nil)
        }

        return MemoryFile(
            id: id, label: label, sublabel: sublabel, path: path,
            content: content, sizeBytes: (attrs[.size] as? Int) ?? data.count
        )
    }

    private func decodeProjectPath(_ projectId: String) -> String? {
        guard projectId.hasPrefix("-") else { return nil }
        let path = "/" + projectId.dropFirst().replacingOccurrences(of: "-", with: "/")
        guard fm.fileExists(atPath: path) ||
              fm.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path) else {
            return nil
        }
        return path
    }
}

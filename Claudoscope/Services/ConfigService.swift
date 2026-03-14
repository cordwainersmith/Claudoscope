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
            body: parsed.body,
            sizeBytes: sizeBytes
        )
    }

    /// Parse a SKILL.md file, extracting frontmatter metadata and body content.
    private func parseSkillContent(_ content: String) -> (name: String?, description: String?, body: String) {
        let lines = content.components(separatedBy: "\n")
        var name: String?
        var description: String?
        var bodyStartIndex = 0
        var inFrontmatter = true

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if inFrontmatter {
                if trimmed == "---" {
                    bodyStartIndex = index + 1
                    inFrontmatter = false
                    continue
                }
                if trimmed.hasPrefix("name:") {
                    name = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    bodyStartIndex = index + 1
                } else if trimmed.hasPrefix("description:") {
                    description = String(trimmed.dropFirst(12)).trimmingCharacters(in: .whitespaces)
                    bodyStartIndex = index + 1
                } else if !trimmed.isEmpty && !trimmed.hasPrefix("name:") && !trimmed.hasPrefix("description:") {
                    // First non-metadata line, treat everything from here as body
                    inFrontmatter = false
                    bodyStartIndex = index
                }
            }
        }

        let bodyLines = Array(lines[bodyStartIndex...])
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        return (name, description, body)
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

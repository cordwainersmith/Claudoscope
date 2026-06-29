import Foundation

extension ConfigService {
    /// Load MCP servers from all known config locations.
    /// Sources (earlier entries win on name collisions):
    ///   1. ~/.claude/claude.json  "mcpServers"
    ///   2. ~/.claude/settings.json  "mcpServers"
    ///   3. ~/.claude.json  "mcpServers" (legacy / older Claude Code versions)
    ///   4. <projectPath>/.mcp.json  "mcpServers" (project-level)
    func loadMcpServers(projectPath: String? = nil) -> [McpServerEntry] {
        var globalMerged: [String: [String: Any]] = [:]

        // OAuth needs-login hint cache (no secrets: timestamps/hashes keyed by
        // server name). A server appears here when Claude Code saw it return
        // 401/403. Tokens themselves live in the Keychain and are NOT read.
        let authCacheKeys: Set<String> = {
            guard let json = readJSON(at: claudeDir.appendingPathComponent("mcp-needs-auth-cache.json")) else { return [] }
            return Set(json.keys)
        }()

        // 1. ~/.claude/claude.json (primary source)
        if let claudeJson = readJSON(at: claudeDir.appendingPathComponent("claude.json")),
           let servers = claudeJson["mcpServers"] as? [String: [String: Any]] {
            for (name, config) in servers {
                globalMerged[name] = config
            }
        }

        // 2. ~/.claude/settings.json
        if let settings = readJSON(at: claudeDir.appendingPathComponent("settings.json")),
           let servers = settings["mcpServers"] as? [String: [String: Any]] {
            for (name, config) in servers {
                if globalMerged[name] == nil {
                    globalMerged[name] = config
                }
            }
        }

        // 3. ~/.claude.json (legacy, per-project MCPs under "projects.<path>.mcpServers")
        let homeDotClaude = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        if let legacyJson = readJSON(at: homeDotClaude),
           let projectsDict = legacyJson["projects"] as? [String: [String: Any]] {
            for (projPath, projData) in projectsDict {
                // If a project is selected, only include MCPs from that project
                if let projectPath = projectPath, projPath != projectPath { continue }
                guard let servers = projData["mcpServers"] as? [String: [String: Any]] else { continue }
                for (name, config) in servers {
                    if globalMerged[name] == nil {
                        globalMerged[name] = config
                    }
                }
            }
        }

        var entries: [McpServerEntry] = []

        for (name, serverDict) in globalMerged {
            entries.append(mcpEntry(name: name, serverDict: serverDict, level: "global", authCacheKeys: authCacheKeys))
        }

        // 4. Project-level .mcp.json
        if let projectPath = projectPath {
            let mcpFile = URL(fileURLWithPath: projectPath).appendingPathComponent(".mcp.json")
            if let mcpJson = readJSON(at: mcpFile),
               let servers = mcpJson["mcpServers"] as? [String: [String: Any]] {
                for (name, config) in servers {
                    if !entries.contains(where: { $0.name == name }) {
                        entries.append(mcpEntry(name: name, serverDict: config, level: "project", authCacheKeys: authCacheKeys))
                    }
                }
            }
        }

        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return entries
    }

    func mcpEntry(name: String, serverDict: [String: Any], level: String, authCacheKeys: Set<String>) -> McpServerEntry {
        let url = serverDict["url"] as? String
        let authStatus: McpAuthStatus
        if url == nil {
            authStatus = .notApplicable                  // stdio: no OAuth
        } else if authCacheKeys.contains(name) {
            authStatus = .needsLogin                     // flagged by Claude Code
        } else {
            authStatus = .authenticated                  // best-effort: not flagged
        }
        return McpServerEntry(
            name: name,
            command: serverDict["command"] as? String,
            args: serverDict["args"] as? [String] ?? [],
            url: url,
            env: serverDict["env"] as? [String: String] ?? [:],
            level: level,
            authStatus: authStatus
        )
    }
}

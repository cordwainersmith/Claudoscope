import Foundation

extension ConfigService {
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
                sublabel: "repo",
                url: URL(fileURLWithPath: decodedPath).appendingPathComponent("CLAUDE.md")
            ))
        }

        // 3. User's private per-project CLAUDE.md
        if let projectId {
            let projectDir = claudeDir
                .appendingPathComponent("projects")
                .appendingPathComponent(projectId)
            files.append(makeMemoryFile(
                id: "user-project",
                label: "CLAUDE.md",
                sublabel: "private",
                url: projectDir.appendingPathComponent("CLAUDE.md")
            ))
        }

        // 4. MEMORY.md
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

    func makeMemoryFile(id: String, label: String, sublabel: String, url: URL) -> MemoryFile {
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

    func maskEmail(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return "***" }
        let local = parts[0]
        let domain = parts[1]
        let prefix = local.prefix(2)
        return "\(prefix)***@\(domain)"
    }

    func decodeProjectPath(_ projectId: String) -> String? {
        guard projectId.hasPrefix("-") else { return nil }
        let segments = projectId.dropFirst().split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard !segments.isEmpty else { return nil }

        var resolved = ""
        var i = 0
        while i < segments.count {
            var candidate = resolved + "/" + segments[i]
            var j = i
            // If this single segment isn't a directory, try joining with next segments via hyphen
            while !fm.fileExists(atPath: candidate) && j + 1 < segments.count {
                j += 1
                candidate += "-" + segments[j]
            }
            resolved = candidate
            i = j + 1
        }

        guard fm.fileExists(atPath: resolved) else { return nil }
        return resolved
    }
}

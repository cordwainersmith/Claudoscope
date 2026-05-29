import Foundation

/// Reads Claude Code configuration data from ~/.claude/ filesystem.
/// Handles settings.json (hooks), claude.json (MCPs), commands, skills, and memory files.
actor ConfigService {
    let claudeDir: URL
    let fm = FileManager.default

    init(claudeDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")) {
        self.claudeDir = claudeDir
    }

    // MARK: - JSON Reading

    func readJSON(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    // MARK: - Hooks

    /// Load hooks merged from all five sources Claude Code itself reads:
    ///   1. ~/.claude/settings.json (user)
    ///   2. <project>/.claude/settings.json (project, checked-in) for each known project
    ///   3. <project>/.claude/settings.local.json (project, gitignored)
    ///   4. Plugin manifests (see ConfigService+Plugins.pluginHookDicts)
    ///   5. /Library/Application Support/ClaudeCode/managed-settings.json
    ///
    /// Hooks are concatenated across sources (Claude Code fires every matching hook),
    /// not deduplicated like MCPs. Each rule carries its source for UI attribution.
    func loadHooks(projectPaths: [(name: String, path: String)] = []) -> [HookEventGroup] {
        var byEvent: [String: [HookRule]] = [:]

        // 1. User
        if let settings = readJSON(at: claudeDir.appendingPathComponent("settings.json")) {
            collectHooksFromSettings(settings, source: .user, into: &byEvent)
        }

        // 2 & 3. Project + project-local
        for project in projectPaths {
            let projectClaudeDir = URL(fileURLWithPath: project.path).appendingPathComponent(".claude")
            if let settings = readJSON(at: projectClaudeDir.appendingPathComponent("settings.json")) {
                collectHooksFromSettings(settings, source: .project(name: project.name), into: &byEvent)
            }
            if let settings = readJSON(at: projectClaudeDir.appendingPathComponent("settings.local.json")) {
                collectHooksFromSettings(settings, source: .local(name: project.name), into: &byEvent)
            }
        }

        // 4. Plugins
        for (pluginName, hooksDict) in pluginHookDicts() {
            collectHooksFromDict(hooksDict, source: .plugin(name: pluginName), into: &byEvent)
        }

        // 5. Managed settings
        let managedURL = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json")
        if let settings = readJSON(at: managedURL) {
            collectHooksFromSettings(settings, source: .managed, into: &byEvent)
        }

        return byEvent
            .map { HookEventGroup(event: $0.key, rules: $0.value) }
            .sorted { $0.event.localizedCompare($1.event) == .orderedAscending }
    }

    /// Read the `hooks` field from a settings-shaped dict and collect into `byEvent`.
    private func collectHooksFromSettings(
        _ settings: [String: Any],
        source: HookSource,
        into byEvent: inout [String: [HookRule]]
    ) {
        guard let hooksDict = settings["hooks"] as? [String: Any] else { return }
        collectHooksFromDict(hooksDict, source: source, into: &byEvent)
    }

    /// Parse a hooks dict (event-name -> array of rule dicts) and collect into `byEvent`.
    /// Iterates dict keys rather than a hardcoded event-name list so new event types
    /// (SessionEnd, PostToolUseFailure, PreCompact, FileChanged, ...) surface automatically.
    private func collectHooksFromDict(
        _ hooksDict: [String: Any],
        source: HookSource,
        into byEvent: inout [String: [HookRule]]
    ) {
        for (eventName, value) in hooksDict {
            guard let rulesArray = value as? [[String: Any]] else { continue }

            for ruleDict in rulesArray {
                let matcher = ruleDict["matcher"] as? String ?? "*"
                guard let hooksArray = ruleDict["hooks"] as? [[String: Any]] else { continue }

                let commands: [HookCommand] = hooksArray.map { hookDict in
                    HookCommand(
                        type: hookDict["type"] as? String,
                        command: hookDict["command"] as? String ?? "",
                        timeout: hookDict["timeout"] as? Int,
                        terminalSequence: hookDict["terminalSequence"] as? String
                    )
                }

                guard !commands.isEmpty else { continue }

                let rule = HookRule(
                    id: UUID().uuidString,
                    matcher: matcher,
                    hooks: commands,
                    source: source
                )
                byEvent[eventName, default: []].append(rule)
            }
        }
    }
}

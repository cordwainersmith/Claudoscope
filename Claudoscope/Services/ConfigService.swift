import Foundation

/// Reads Claude Code configuration data from ~/.claude/ filesystem.
/// Handles settings.json (hooks), claude.json (MCPs), commands, skills, and memory files.
actor ConfigService {
    let claudeDir: URL
    let fm = FileManager.default

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

    func readJSON(at url: URL) -> [String: Any]? {
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
}

import Foundation

extension ConfigLinterService {

    // MARK: - Channel Plugin Checks (CHN001-CHN003)

    /// Channel plugins from the research-preview allowlist (claude-plugins-official).
    /// Matched by exact plugin name, case-insensitive.
    static let knownChannelPluginNames: Set<String> = ["telegram", "discord", "imessage", "fakechat"]

    /// Lint channel-related configuration.
    ///
    /// - CHN001: a known channel plugin is installed and enabled. Channels push
    ///   external messages into live sessions (prompt-injection surface) and can
    ///   relay permission prompts for remote approval.
    /// - CHN002: a channel plugin is enabled but settings.json env selects a
    ///   third-party provider (Vertex/Bedrock), where Claude Code silently
    ///   ignores channels. Best-effort: env vars set only in the shell profile
    ///   are not visible here.
    /// - CHN003: the channelsEnabled policy key is present in settings.json.
    ///
    /// Subject names are quoted in messages so the Config Health UI can surface
    /// them per-row (see `displayLabel(for:)`).
    func lintChannels(plugins: [PluginInfo], globalClaudeDir: URL) -> [LintResult] {
        var results: [LintResult] = []
        let settingsPath = globalClaudeDir.appendingPathComponent("settings.json").path

        let json: [String: Any]? = {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }()

        let channelPlugins = plugins.filter {
            Self.knownChannelPluginNames.contains($0.name.lowercased()) && $0.enabled
        }

        // CHN001: enabled channel plugin (one result per plugin)
        for plugin in channelPlugins {
            results.append(LintResult(
                severity: .warning,
                checkId: .CHN001,
                filePath: settingsPath,
                message: "Channel plugin \"\(plugin.fullName)\" is installed and enabled. Channels push external messages directly into this machine's live sessions.",
                fix: "Confirm sender gating/pairing is configured for the channel, and review whether permission relay (remote tool approvals) is intended.",
                displayPath: "Plugins"
            ))
        }

        // CHN002: channel plugin enabled but a third-party provider is selected
        let envSection = json?["env"] as? [String: Any]
        if let signalKey = thirdPartyProviderSignal(env: envSection) {
            for plugin in channelPlugins {
                results.append(LintResult(
                    severity: .info,
                    checkId: .CHN002,
                    filePath: settingsPath,
                    message: "Channel plugin \"\(plugin.fullName)\" is enabled, but settings.json env selects a third-party provider (\(signalKey)). Channels are silently ignored on Vertex/Bedrock.",
                    fix: "Remove the unused channel plugin, or expect channels to activate only under a first-party Anthropic login.",
                    displayPath: "Plugins"
                ))
            }
        }

        // CHN003: channelsEnabled policy key present (either value is policy-relevant)
        if let channelsEnabled = json?["channelsEnabled"] as? Bool {
            results.append(LintResult(
                severity: .info,
                checkId: .CHN003,
                filePath: settingsPath,
                message: "channelsEnabled is set to \(channelsEnabled) in settings.json.",
                displayPath: "settings.json"
            ))
        }

        return results
    }

    /// Returns the env key indicating a third-party provider, or nil for
    /// first-party (or undetectable) setups.
    private func thirdPartyProviderSignal(env: [String: Any]?) -> String? {
        guard let env else { return nil }
        for key in ["CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_BEDROCK"] {
            if isTruthy(env[key]) { return key }
        }
        if let projectId = env["ANTHROPIC_VERTEX_PROJECT_ID"] as? String, !projectId.isEmpty {
            return "ANTHROPIC_VERTEX_PROJECT_ID"
        }
        return nil
    }

    /// Env values are usually strings, but be liberal about JSON types.
    private func isTruthy(_ value: Any?) -> Bool {
        switch value {
        case let bool as Bool: return bool
        case let int as Int: return int != 0
        case let string as String: return ["1", "true", "yes"].contains(string.lowercased())
        default: return false
        }
    }
}

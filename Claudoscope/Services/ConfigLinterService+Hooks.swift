import Foundation

extension ConfigLinterService {

    // MARK: - Hook Matcher Checks (HOOK001-HOOK004)

    /// Events whose matcher is compared against a tool name (PreToolUse, etc.).
    /// MCP-tool and comma-list checks only make sense for these.
    static let hookToolMatcherEvents: Set<String> = [
        "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "PermissionRequest", "PermissionDenied"
    ]

    /// Events that ignore the matcher field entirely; a matcher here is dead config.
    static let hookNoMatcherEvents: Set<String> = [
        "UserPromptSubmit", "PostToolBatch", "Stop", "TeammateIdle",
        "TaskCreated", "TaskCompleted", "WorktreeCreate", "WorktreeRemove",
        "CwdChanged"
    ]

    enum MatcherKind: Equatable {
        case matchAll
        case exactList([String])
        case regex
    }

    /// Classify a hook matcher the way Claude Code does: "*" or "" match all;
    /// strings made only of letters, digits, underscore, space, comma, or pipe
    /// are exact (a ","/"|"-separated list of literal tool names); anything else
    /// (hyphens, dots, anchors, ...) is treated as a JavaScript regex.
    static func classifyMatcher(_ matcher: String) -> MatcherKind {
        if matcher == "*" || matcher.isEmpty { return .matchAll }
        if matcher.range(of: "^[A-Za-z0-9_ ,|]*$", options: .regularExpression) != nil {
            let tokens = matcher
                .split(whereSeparator: { $0 == "," || $0 == "|" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return .exactList(tokens)
        }
        return .regex
    }

    /// True when a token names an MCP server but no tool (e.g. "mcp__memory" or
    /// the hyphenated "mcp__brave-search"), so it matches no real tool. Real MCP
    /// tools are named "mcp__<server>__<tool>".
    static func isMcpServerWithoutTool(_ token: String) -> Bool {
        guard token.hasPrefix("mcp__") else { return false }
        if token.contains(".*") || token.contains(".+") { return false }
        let rest = String(token.dropFirst("mcp__".count))
        return !rest.isEmpty && !rest.contains("__")
    }

    /// Extract MCP server names from "mcp__<server>__..." occurrences in a
    /// matcher. Returns [] for a bare "mcp__server" (handled by HOOK001).
    static func mcpServerRefs(_ matcher: String) -> [String] {
        var servers: [String] = []
        var remainder = Substring(matcher)
        while let prefix = remainder.range(of: "mcp__") {
            let after = remainder[prefix.upperBound...]
            if let sep = after.range(of: "__") {
                let server = String(after[..<sep.lowerBound])
                if !server.isEmpty { servers.append(server) }
                remainder = after[sep.upperBound...]
            } else {
                break
            }
        }
        return servers
    }

    func lintHooks(hookGroups: [HookEventGroup], mcpServerNames: Set<String>) -> [LintResult] {
        var results: [LintResult] = []

        for group in hookGroups {
            let event = group.event
            let takesToolMatcher = Self.hookToolMatcherEvents.contains(event)
            let ignoresMatcher = Self.hookNoMatcherEvents.contains(event)

            for rule in group.rules {
                let matcher = rule.matcher
                let kind = Self.classifyMatcher(matcher)
                let path = Self.hookSourceDisplayPath(rule.source)

                // HOOK004: matcher present on an event that ignores it.
                if ignoresMatcher, kind != .matchAll {
                    results.append(LintResult(
                        severity: .info,
                        checkId: .HOOK004,
                        filePath: path,
                        message: "The \"\(event)\" event ignores matchers; matcher \"\(matcher)\" is silently ignored and the hook always fires.",
                        fix: "Remove the matcher field from this \(event) hook.",
                        displayPath: path
                    ))
                }

                guard takesToolMatcher else { continue }

                // HOOK001: mcp__ matcher with no tool segment matches no real tool.
                let brokenMcpTokens: [String]
                switch kind {
                case .exactList(let tokens):
                    brokenMcpTokens = tokens.filter { Self.isMcpServerWithoutTool($0) }
                case .regex:
                    brokenMcpTokens = Self.isMcpServerWithoutTool(matcher) ? [matcher] : []
                case .matchAll:
                    brokenMcpTokens = []
                }
                for token in brokenMcpTokens {
                    results.append(LintResult(
                        severity: .warning,
                        checkId: .HOOK001,
                        filePath: path,
                        message: "Hook matcher \"\(token)\" names an MCP server but has no tool segment, so it matches no tool (Claude Code 2.1.195 made hyphenated/exact matchers exact-match).",
                        fix: "Replace \"\(token)\" with \"\(token)__.*\" to match all tools from that server.",
                        displayPath: path
                    ))
                }

                // HOOK002: comma-separated exact-list matcher.
                if case .exactList = kind, matcher.contains(",") {
                    let piped = matcher.replacingOccurrences(of: ",", with: "|")
                    results.append(LintResult(
                        severity: .warning,
                        checkId: .HOOK002,
                        filePath: path,
                        message: "Hook matcher \"\(matcher)\" uses a comma separator, which silently never fired before Claude Code 2.1.191.",
                        fix: "Use \"|\" as the separator (e.g. \"\(piped)\").",
                        displayPath: path
                    ))
                }

                // HOOK003: matcher targets an MCP server not in the loaded config.
                // Only when servers were actually loaded, so a setup where MCP
                // discovery returned nothing does not flag every matcher.
                if !mcpServerNames.isEmpty {
                    for server in Self.mcpServerRefs(matcher) where !mcpServerNames.contains(server) {
                        results.append(LintResult(
                            severity: .info,
                            checkId: .HOOK003,
                            filePath: path,
                            message: "Hook matcher \"\(matcher)\" targets MCP server \"\(server)\", which is not in the loaded configuration (possible typo or removed server).",
                            fix: "Verify the server name. Plugin-provided MCP servers are not always detected.",
                            displayPath: path
                        ))
                    }
                }
            }
        }

        return results
    }

    /// A stable, informative path string per hook source. Used for both the
    /// displayed path and `LintResult.id` uniqueness (loadHooks discards the
    /// real file path, so we synthesize a per-source label).
    private static func hookSourceDisplayPath(_ source: HookSource) -> String {
        switch source {
        case .user: return "~/.claude/settings.json"
        case .project(let name): return "\(name)/.claude/settings.json"
        case .local(let name): return "\(name)/.claude/settings.local.json"
        case .plugin(let name): return "plugin: \(name)"
        case .managed: return "managed-settings.json"
        }
    }
}

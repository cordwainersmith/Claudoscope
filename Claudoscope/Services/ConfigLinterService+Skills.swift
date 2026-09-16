import Foundation

extension ConfigLinterService {

    // MARK: - Skills Linting

    /// One installed skill, for the cross-scope duplicate check (SKL015).
    struct SkillIdentity: Sendable {
        let name: String
        let filePath: String
        let scope: String
        let displayPath: String
    }

    func lintSkills(
        skillsDir: URL,
        scope: String = "user",
        mcpServerNames: Set<String> = []
    ) -> (results: [LintResult], descriptions: [String], identities: [SkillIdentity]) {
        var results: [LintResult] = []
        var descriptions: [String] = []
        var identities: [SkillIdentity] = []

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: skillsDir.path, isDirectory: &isDir), isDir.boolValue else {
            return (results, descriptions, identities)
        }

        guard let skillDirs = try? fm.contentsOfDirectory(at: skillsDir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return (results, descriptions, identities)
        }

        for skillDir in skillDirs {
            var isDirFlag: ObjCBool = false
            guard fm.fileExists(atPath: skillDir.path, isDirectory: &isDirFlag), isDirFlag.boolValue else { continue }

            let dirName = skillDir.lastPathComponent
            let skillFilePath = skillDir.appendingPathComponent("SKILL.md")

            // SKL001: check for wrong casing of SKILL.md
            if !fm.fileExists(atPath: skillFilePath.path) {
                // Look for any case variant
                if let dirContents = try? fm.contentsOfDirectory(atPath: skillDir.path) {
                    let wrongCased = dirContents.first { item in
                        item.lowercased() == "skill.md" && item != "SKILL.md"
                    }
                    if let wrongName = wrongCased {
                        results.append(LintResult(
                            severity: .error,
                            checkId: .SKL001,
                            filePath: skillDir.appendingPathComponent(wrongName).path,
                            message: "Skill file named '\(wrongName)' but must be exactly 'SKILL.md' (all caps).",
                            fix: "Rename the file to 'SKILL.md'.",
                            displayPath: dirName
                        ))
                    }
                }
                continue
            }

            guard let content = try? String(contentsOf: skillFilePath, encoding: .utf8) else { continue }

            let parsed = parseSkillContent(content)
            let path = skillFilePath.path

            // SKL002: missing name
            if parsed.name == nil {
                results.append(LintResult(
                    severity: .warning,
                    checkId: .SKL002,
                    filePath: path,
                    message: "Skill is missing a 'name' field in frontmatter. Claude Code will default to the directory name '\(dirName)'.",
                    fix: "Add 'name: \(dirName)' to the SKILL.md frontmatter.",
                    displayPath: dirName
                ))
            }

            // SKL003: missing description
            if parsed.description == nil {
                results.append(LintResult(
                    severity: .error,
                    checkId: .SKL003,
                    filePath: path,
                    message: "Skill is missing a 'description' field in frontmatter. This field is required for Claude to discover and use the skill.",
                    fix: "Add a 'description' field to the SKILL.md frontmatter.",
                    displayPath: dirName
                ))
            } else {
                descriptions.append(parsed.description!)
            }

            // SKL004: name doesn't match directory
            if let name = parsed.name, name != dirName {
                results.append(LintResult(
                    severity: .error,
                    checkId: .SKL004,
                    filePath: path,
                    message: "Skill name '\(name)' does not match directory name '\(dirName)'.",
                    fix: "Rename the skill to '\(dirName)' or rename the directory to '\(name)'.",
                    displayPath: dirName
                ))
            }

            // SKL005: name not kebab-case
            if let name = parsed.name {
                if !isValidKebabCase(name) {
                    results.append(LintResult(
                        severity: .error,
                        checkId: .SKL005,
                        filePath: path,
                        message: "Skill name '\(name)' is not valid kebab-case. Must be lowercase alphanumeric with single hyphens, not starting or ending with a hyphen.",
                        fix: "Rename to a valid kebab-case identifier (e.g., 'my-skill-name').",
                        displayPath: dirName
                    ))
                }
            }

            // SKL006: name >64 chars
            if let name = parsed.name, name.count > 64 {
                results.append(LintResult(
                    severity: .error,
                    checkId: .SKL006,
                    filePath: path,
                    message: "Skill name is \(name.count) characters, exceeding the 64-character limit.",
                    fix: "Shorten the skill name to 64 characters or fewer.",
                    displayPath: dirName
                ))
            }

            // SKL007: description >1024 chars
            if let desc = parsed.description, desc.count > 1024 {
                results.append(LintResult(
                    severity: .error,
                    checkId: .SKL007,
                    filePath: path,
                    message: "Skill description is \(desc.count) characters, exceeding the 1,024-character limit.",
                    fix: "Shorten the description to 1,024 characters or fewer.",
                    displayPath: dirName
                ))
            }

            // SKL008: XML angle brackets in name or description
            if let name = parsed.name, (name.contains("<") || name.contains(">")) {
                results.append(LintResult(
                    severity: .error,
                    checkId: .SKL008,
                    filePath: path,
                    message: "Skill name contains XML angle brackets ('<' or '>'). These can break frontmatter parsing.",
                    fix: "Remove angle brackets from the name field.",
                    displayPath: dirName
                ))
            }
            if let desc = parsed.description, (desc.contains("<") || desc.contains(">")) {
                results.append(LintResult(
                    severity: .error,
                    checkId: .SKL008,
                    filePath: path,
                    message: "Skill description contains XML angle brackets ('<' or '>'). These can break frontmatter parsing.",
                    fix: "Remove angle brackets from the description field.",
                    displayPath: dirName
                ))
            }

            // SKL009: reserved words in name
            if let name = parsed.name {
                let lower = name.lowercased()
                let reservedWords = ["claude", "anthropic"]
                for reserved in reservedWords {
                    if lower.contains(reserved) {
                        results.append(LintResult(
                            severity: .error,
                            checkId: .SKL009,
                            filePath: path,
                            message: "Skill name '\(name)' contains reserved word '\(reserved)'.",
                            fix: "Remove '\(reserved)' from the skill name.",
                            displayPath: dirName
                        ))
                        break
                    }
                }
            }

            // SKL012: body >500 lines
            let bodyLines = parsed.body.components(separatedBy: "\n")
            if bodyLines.count > 500 {
                results.append(LintResult(
                    severity: .warning,
                    checkId: .SKL012,
                    filePath: path,
                    message: "Skill body has \(bodyLines.count) lines, exceeding 500. Large skill bodies consume significant context.",
                    fix: "Condense the skill body or split into multiple skills.",
                    displayPath: dirName
                ))
            }

            // SKL013: allowed-tools / disallowed-tools malformed or contradictory
            // SKL011: an mcp__ tool naming a server that is not configured
            results.append(contentsOf: lintSkillToolRestrictions(
                content: content, filePath: path, displayPath: dirName,
                mcpServerNames: mcpServerNames
            ))

            // SKL010: relative links that point at nothing
            results.append(contentsOf: lintSkillRelativeLinks(
                body: parsed.body, skillDir: skillDir, filePath: path, displayPath: dirName
            ))

            identities.append(SkillIdentity(
                name: parsed.name ?? dirName,
                filePath: path,
                scope: scope,
                displayPath: dirName
            ))
        }

        return (results, descriptions, identities)
    }

    // MARK: - SKL016: installed skill with no attributed run

    /// Below this many attributed skill turns across the corpus, "never ran" is
    /// indistinguishable from "the transcripts predate attribution tagging"
    /// (Claude Code only started stamping `attributionSkill` in 2.1.24x, so
    /// coverage on an older corpus is near zero). The check stays silent.
    static let sklUnusedMinAttributedTurns = 200

    /// SKL016: an installed skill that never appears in any attributed turn.
    /// Informational, not a defect: it is the signal for pruning a skill that
    /// is costing description budget (see SKL_AGG) and earning nothing.
    func lintUnusedSkills(skills: [SkillEntry], attribution: AttributionRollup) -> [LintResult] {
        let attributedTurns = attribution.skills.reduce(0) { $0 + $1.turnCount }
        guard attributedTurns >= Self.sklUnusedMinAttributedTurns else { return [] }

        let ranKeys = Set(attribution.skills.map { AttributionEngine.canonicalSkillKey($0.skill) })

        return skills
            .filter { !ranKeys.contains(AttributionEngine.canonicalSkillKey($0.name)) }
            .sorted { $0.name < $1.name }
            .map { skill in
                LintResult(
                    severity: .info,
                    checkId: .SKL016,
                    filePath: skill.path ?? skill.displayName,
                    message: "Skill \"\(skill.name)\" has no attributed turns across \(attributedTurns) tagged skill turns. Its description still occupies context on every request.",
                    fix: "Remove the skill, or sharpen its description so Claude reaches for it.",
                    displayPath: skill.displayName
                )
            }
    }

    // MARK: - SKL015: duplicate skill names across scopes

    /// One finding per duplicated name, listing the scopes it was found in.
    /// Two copies in the same scope cannot happen (the directory name is the
    /// key), so this is always a cross-scope collision.
    func lintDuplicateSkillNames(_ identities: [SkillIdentity]) -> [LintResult] {
        var byName: [String: [SkillIdentity]] = [:]
        for identity in identities {
            byName[identity.name, default: []].append(identity)
        }

        return byName
            .filter { $0.value.count > 1 }
            .sorted { $0.key < $1.key }
            .map { name, copies in
                let scopes = copies.map(\.scope).sorted().joined(separator: " and ")
                return LintResult(
                    severity: .warning,
                    checkId: .SKL015,
                    filePath: copies.sorted { $0.scope < $1.scope }[0].filePath,
                    message: "Skill \"\(name)\" is defined in \(scopes) scope. Claude Code loads one of them without reporting which, so edits can land in the copy that is not running.",
                    fix: "Rename one of the copies, or delete the one you do not want.",
                    displayPath: copies[0].displayPath
                )
            }
    }

    // MARK: - SKL010: relative links

    /// Flags a markdown link whose target is a relative path that does not exist
    /// under the skill directory. Only paths that look like files (they contain a
    /// "/" or a "." ) are checked, so prose placeholders like `[see](URL)` are not
    /// reported as broken references.
    func lintSkillRelativeLinks(body: String, skillDir: URL, filePath: String, displayPath: String) -> [LintResult] {
        var seen: Set<String> = []
        var results: [LintResult] = []

        for target in Self.markdownLinkTargets(in: body) {
            guard Self.isCheckableRelativePath(target) else { continue }
            let path = String(target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
            guard !path.isEmpty, seen.insert(path).inserted else { continue }

            let resolved = URL(fileURLWithPath: path, relativeTo: skillDir).standardizedFileURL
            guard !fm.fileExists(atPath: resolved.path) else { continue }

            results.append(LintResult(
                severity: .warning,
                checkId: .SKL010,
                filePath: filePath,
                message: "SKILL.md links to \"\(path)\", which does not exist in the skill directory.",
                fix: "Add the referenced file, or correct the path.",
                displayPath: displayPath
            ))
        }
        return results
    }

    /// Markdown link and image targets: the `(...)` half of `[text](target)`.
    static func markdownLinkTargets(in body: String) -> [String] {
        var targets: [String] = []
        var searchRange = body.startIndex..<body.endIndex
        while let match = body.range(of: "\\]\\([^)\\s]+\\)", options: .regularExpression, range: searchRange) {
            let inner = body[match.lowerBound..<match.upperBound].dropFirst(2).dropLast()
            targets.append(String(inner))
            searchRange = match.upperBound..<body.endIndex
        }
        return targets
    }

    /// True for a link target worth resolving against the skill directory: a
    /// relative path that names a file. Absolute paths, URLs, anchors, shell
    /// variables and templated placeholders are somebody else's problem.
    static func isCheckableRelativePath(_ target: String) -> Bool {
        if target.isEmpty { return false }
        if target.contains("://") { return false }
        for prefix in ["#", "/", "~", "$", "mailto:", "tel:"] where target.hasPrefix(prefix) { return false }
        if target.contains("{") || target.contains("<") { return false }
        let path = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        return path.contains("/") || path.contains(".")
    }

    // MARK: - Tool Restriction Validation

    /// Built-in tools known to Claude Code. Any name starting with "mcp__" is also
    /// valid. Err on the side of inclusion: an extra name here means a genuinely
    /// misspelled tool goes unflagged, while a missing one warns about working
    /// config, which is what a 12-entry version of this list did for every skill
    /// that named Agent, Skill, ToolSearch, or any Task* tool.
    static let knownTools: Set<String> = [
        // File and shell
        "Bash", "BashOutput", "KillShell", "Read", "Write", "Edit", "MultiEdit",
        "Glob", "Grep", "NotebookEdit",
        // Web
        "WebFetch", "WebSearch",
        // Agents and delegation
        "Agent", "Task", "Explore", "Workflow", "SendMessage", "ListAgents",
        // Task/todo tracking (off by default on Opus 5 and newer, see SKL014)
        "TodoWrite", "TaskCreate", "TaskGet", "TaskUpdate", "TaskList",
        "TaskOutput", "TaskStop",
        // Session and planning
        "Skill", "SlashCommand", "AskUserQuestion", "ToolSearch",
        "EnterPlanMode", "ExitPlanMode", "EnterWorktree", "ExitWorktree",
        "ReportFindings", "Monitor", "ScheduleWakeup",
        "CronCreate", "CronDelete", "CronList",
        // MCP plumbing
        "WaitForMcpServers", "ListMcpResourcesTool", "ReadMcpResourceTool",
        "ReadMcpResourceDirTool",
    ]

    /// The server half of an `mcp__<server>__<tool>` (or bare `mcp__<server>`)
    /// reference. Server names can contain hyphens but never a `__` separator.
    static func mcpServerSegment(of tool: String) -> String? {
        guard tool.hasPrefix("mcp__") else { return nil }
        let rest = String(tool.dropFirst(5))
        guard !rest.isEmpty else { return nil }
        if let sep = rest.range(of: "__") {
            let server = String(rest[rest.startIndex..<sep.lowerBound])
            return server.isEmpty ? nil : server
        }
        return rest
    }

    /// Task-tracking tools, removed from Opus 4.8, Sonnet 5, Fable 5, Mythos 5, and
    /// newer models in CC 2.1.233 unless `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` is set.
    static let todoTools: Set<String> = [
        "TodoWrite", "TaskCreate", "TaskGet", "TaskUpdate", "TaskList"
    ]

    func lintSkillToolRestrictions(
        content: String,
        filePath: String,
        displayPath: String,
        mcpServerNames: Set<String> = []
    ) -> [LintResult] {
        var results: [LintResult] = []
        let (allowed, disallowed) = parseToolRestrictions(from: content)

        guard allowed != nil || disallowed != nil else { return results }

        let allowedSet = Set(allowed ?? [])
        let disallowedSet = Set(disallowed ?? [])

        // Check for unknown tool names in both lists
        var reportedServers: Set<String> = []
        for tool in (allowed ?? []) + (disallowed ?? []) {
            if tool.hasPrefix("mcp__") {
                // SKL011: the server half must name a server that is actually
                // configured, or the restriction silently matches nothing.
                // Skipped entirely when no servers are known, so a corpus with
                // an unreadable MCP config does not flag every entry.
                guard !mcpServerNames.isEmpty,
                      let server = Self.mcpServerSegment(of: tool),
                      !mcpServerNames.contains(server),
                      reportedServers.insert(server).inserted
                else { continue }
                results.append(LintResult(
                    severity: .warning,
                    checkId: .SKL011,
                    filePath: filePath,
                    message: "Tool restriction names MCP server \"\(server)\", which is not configured in any settings file.",
                    fix: "Configure \"\(server)\" as an MCP server, or correct the tool name.",
                    displayPath: displayPath
                ))
                continue
            }
            if !Self.knownTools.contains(tool) {
                results.append(LintResult(
                    severity: .warning,
                    checkId: .SKL013,
                    filePath: filePath,
                    message: "Unknown tool name \"\(tool)\" in skill tool restrictions.",
                    fix: "Correct the tool name or remove it from allowed-tools / disallowed-tools.",
                    displayPath: displayPath
                ))
            }
        }

        // SKL014: a skill allowed ONLY todo tools has nothing to run on a current
        // model. Restricting to them alongside other tools is fine — the skill just
        // loses the tracking, not its ability to work.
        if let allowed, !allowed.isEmpty, allowedSet.isSubset(of: Self.todoTools) {
            results.append(LintResult(
                severity: .warning,
                checkId: .SKL014,
                filePath: filePath,
                message: "allowed-tools is limited to \(allowed.sorted().joined(separator: ", ")), which Claude Code removed from Opus 4.8, Sonnet 5, Fable 5, Mythos 5, and newer models.",
                fix: "Widen allowed-tools, or set CLAUDE_CODE_ENABLE_TODO_TOOLS=1 to restore the todo tools.",
                displayPath: displayPath
            ))
        }

        // Check for tools listed in both allowed and disallowed (contradictory)
        let contradictions = allowedSet.intersection(disallowedSet)
        for tool in contradictions.sorted() {
            results.append(LintResult(
                severity: .error,
                checkId: .SKL013,
                filePath: filePath,
                message: "Tool \"\(tool)\" appears in both allowed-tools and disallowed-tools, which is contradictory.",
                fix: "Remove \"\(tool)\" from either allowed-tools or disallowed-tools.",
                displayPath: displayPath
            ))
        }

        return results
    }

    /// Parse allowed-tools and disallowed-tools from YAML frontmatter (--- ... ---).
    func parseToolRestrictions(from content: String) -> (allowed: [String]?, disallowed: [String]?) {
        let lines = content.components(separatedBy: "\n")
        guard let firstNonEmpty = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              firstNonEmpty.trimmingCharacters(in: .whitespaces) == "---" else {
            return (nil, nil)
        }

        var allowed: [String]?
        var disallowed: [String]?
        var inFrontmatter = true
        var seenOpen = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !seenOpen {
                if trimmed == "---" { seenOpen = true }
                continue
            }
            if trimmed == "---" { inFrontmatter = false; break }
            guard inFrontmatter else { break }

            if trimmed.hasPrefix("allowed-tools:") {
                let raw = String(trimmed.dropFirst("allowed-tools:".count)).trimmingCharacters(in: .whitespaces)
                allowed = parseToolListFromValue(raw)
            } else if trimmed.hasPrefix("disallowed-tools:") {
                let raw = String(trimmed.dropFirst("disallowed-tools:".count)).trimmingCharacters(in: .whitespaces)
                disallowed = parseToolListFromValue(raw)
            }
        }

        return (allowed, disallowed)
    }

    private func parseToolListFromValue(_ raw: String) -> [String]? {
        let stripped = raw.trimmingCharacters(in: .whitespaces)
        guard !stripped.isEmpty else { return nil }

        if stripped.hasPrefix("[") && stripped.hasSuffix("]") {
            let inner = String(stripped.dropFirst().dropLast())
            let tools = inner.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return tools.isEmpty ? nil : tools
        }

        let tools = stripped.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return tools.isEmpty ? nil : tools
    }

    // MARK: - Skill Parsing

    func parseSkillContent(_ content: String) -> (name: String?, description: String?, body: String) {
        let lines = content.components(separatedBy: "\n")
        var name: String?
        var description: String?
        var bodyStartIndex = 0
        var inFrontmatter = false
        var seenOpeningFence = false
        var currentKey: String?
        var currentValue: String?

        func flushCurrentKey() {
            if let key = currentKey, let value = currentValue {
                let trimmedValue = value.trimmingCharacters(in: .whitespaces)
                switch key {
                case "name": name = trimmedValue
                case "description": description = trimmedValue
                default: break
                }
            }
            currentKey = nil
            currentValue = nil
        }

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Look for opening --- fence
            if !seenOpeningFence {
                if trimmed == "---" {
                    seenOpeningFence = true
                    inFrontmatter = true
                    bodyStartIndex = index + 1
                    continue
                }
                // No opening fence, treat as body-only (no frontmatter)
                if !trimmed.isEmpty {
                    break
                }
                bodyStartIndex = index + 1
                continue
            }

            guard inFrontmatter else { break }

            // Closing --- fence
            if trimmed == "---" {
                flushCurrentKey()
                bodyStartIndex = index + 1
                inFrontmatter = false
                continue
            }

            if trimmed.isEmpty {
                flushCurrentKey()
                bodyStartIndex = index + 1
                inFrontmatter = false
                continue
            }

            if let colonRange = trimmed.range(of: ":"),
               colonRange.lowerBound != trimmed.startIndex {
                let key = String(trimmed[trimmed.startIndex..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty && key.range(of: "^[a-zA-Z_][a-zA-Z0-9_-]*$", options: .regularExpression) != nil {
                    flushCurrentKey()
                    let value = String(trimmed[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    currentKey = key
                    currentValue = value
                    bodyStartIndex = index + 1
                    continue
                }
            }

            if currentKey != nil && (line.hasPrefix("  ") || line.hasPrefix("\t")) {
                currentValue = (currentValue ?? "") + "\n" + trimmed
                bodyStartIndex = index + 1
                continue
            }

            flushCurrentKey()
            inFrontmatter = false
            bodyStartIndex = index
        }

        flushCurrentKey()

        let bodyLines = Array(lines[bodyStartIndex...])
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        return (name, description, body)
    }

    // MARK: - Kebab-case Validation

    func isValidKebabCase(_ name: String) -> Bool {
        // Must be lowercase alphanumeric with single hyphens, not starting or ending with hyphen
        guard !name.isEmpty else { return false }
        if name.hasPrefix("-") || name.hasSuffix("-") { return false }
        if name.contains("--") { return false }
        // Only lowercase letters, digits, and hyphens
        return name.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil
    }
}

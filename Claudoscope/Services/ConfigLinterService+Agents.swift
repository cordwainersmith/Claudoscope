import Foundation

extension ConfigLinterService {

    // MARK: - Agent Definition Checks (AGT)

    /// Lints subagent definitions in `~/.claude/agents/*.md` and
    /// `<project>/.claude/agents/*.md` against limits Claude Code added in
    /// 2.1.292-2.1.299.
    func lintAgents(projectRoot: String?, globalDir: URL, mcpServerNames: Set<String>) -> [LintResult] {
        var dirs: [(url: URL, label: String)] = [(globalDir.appendingPathComponent("agents"), "~/.claude/agents")]
        if let root = projectRoot {
            dirs.append((URL(fileURLWithPath: root).appendingPathComponent(".claude/agents"), ".claude/agents"))
        }
        var results: [LintResult] = []
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir.url, includingPropertiesForKeys: nil) else { continue }
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "md" {
                guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
                results += lintAgentDefinition(
                    content: content,
                    filePath: file.path,
                    displayPath: "\(dir.label)/\(file.lastPathComponent)",
                    mcpServerNames: mcpServerNames
                )
            }
        }
        return results
    }

    func lintAgentDefinition(content: String, filePath: String, displayPath: String, mcpServerNames: Set<String>) -> [LintResult] {
        let parsed = Claudoscope.parseFrontmatter(content)
        var results: [LintResult] = []

        // AGT002: names over 256 characters are rejected (CC 2.1.292)
        if let name = parsed.name, name.count > 256 {
            results.append(LintResult(
                severity: .error,
                checkId: .AGT002,
                filePath: filePath,
                message: "Agent name is \(name.count) characters. Claude Code 2.1.292+ rejects names longer than 256, so this agent is not available.",
                fix: "Shorten the name to 256 characters or fewer.",
                displayPath: displayPath
            ))
        }

        // AGT001: tools: entries relying on MCP prefix matching (CC 2.1.299)
        let tools = Self.frontmatterList(parsed.metadata["tools"])
        for (entry, servers) in Self.staleMcpPrefixRules(tools, servers: Array(mcpServerNames)) {
            results.append(LintResult(
                severity: .warning,
                checkId: .AGT001,
                filePath: filePath,
                message: "tools: entry \"\(entry)\" no longer gives this agent the tools of \(servers.joined(separator: ", ")). Since Claude Code 2.1.299 it reaches only a server named exactly that.",
                fix: servers.map { "mcp__\($0)__*" }.joined(separator: ", "),
                displayPath: displayPath
            ))
        }

        // AGT003: at most 32 skills are preloaded (CC 2.1.295)
        let skills = Self.frontmatterList(parsed.metadata["skills"])
        if skills.count > 32 {
            results.append(LintResult(
                severity: .warning,
                checkId: .AGT003,
                filePath: filePath,
                message: "skills: lists \(skills.count) skills. Claude Code 2.1.295+ preloads only the first 32; the other \(skills.count - 32) are not loaded up front.",
                fix: "Keep the skills this agent always needs; it can still invoke others with the Skill tool.",
                displayPath: displayPath
            ))
        }

        return results
    }

    /// A frontmatter list in any of the shapes agent files use: `a, b`,
    /// `[a, b]`, or a block list of `- a` lines.
    static func frontmatterList(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        let lines = raw.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let items: [String]
        if lines.contains(where: { $0.hasPrefix("- ") }) {
            items = lines.filter { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) }
        } else {
            var text = raw.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("["), text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
            items = text.components(separatedBy: ",")
        }
        return items
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'"))) }
            .filter { !$0.isEmpty }
    }
}

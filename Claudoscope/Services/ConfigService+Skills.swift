import Foundation

extension ConfigService {
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

    func readSkillFile(url: URL, name: String, pluginName: String? = nil) -> SkillEntry? {
        guard fm.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let sizeBytes = (attrs?[.size] as? Int) ?? data.count
        let parsed = parseSkillContent(content)

        // allowed-tools / disallowed-tools land in parsed.metadata under those keys;
        // we normalize them so they're stored as comma-joined strings for downstream
        // consumers (linter, views) that read from metadata.
        var normalizedMetadata = parsed.metadata
        if let raw = normalizedMetadata["allowed-tools"] {
            let tools = parseToolList(raw)
            normalizedMetadata["allowed-tools"] = tools?.joined(separator: ", ")
        }
        if let raw = normalizedMetadata["disallowed-tools"] {
            let tools = parseToolList(raw)
            normalizedMetadata["disallowed-tools"] = tools?.joined(separator: ", ")
        }

        return SkillEntry(
            name: parsed.name ?? name,
            displayName: pluginName != nil ? "\(parsed.name ?? name) (\(pluginName!))" : (parsed.name ?? name),
            description: parsed.description,
            metadata: normalizedMetadata,
            body: parsed.body,
            sizeBytes: sizeBytes
        )
    }

    /// Parse a tool list from a frontmatter value.
    /// Accepts a comma-separated string ("Bash, Read"), an inline YAML array ("[Bash, Read]"),
    /// or a multi-line YAML list (items joined into a single string with "- " prefixes).
    func parseToolList(_ raw: String) -> [String]? {
        let stripped = raw.trimmingCharacters(in: .whitespaces)
        guard !stripped.isEmpty else { return nil }

        // Multi-line YAML list: lines starting with "- "
        if stripped.contains("\n") {
            let tools = stripped.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("- ") }
                .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return tools.isEmpty ? nil : tools
        }

        // Inline YAML array: [Bash, Read]
        if stripped.hasPrefix("[") && stripped.hasSuffix("]") {
            let inner = String(stripped.dropFirst().dropLast())
            let tools = inner.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return tools.isEmpty ? nil : tools
        }

        // Comma-separated: Bash, Read
        let tools = stripped.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return tools.isEmpty ? nil : tools
    }

    /// Parse a SKILL.md file, extracting frontmatter metadata and body content.
    /// Delegates to the shared `parseFrontmatter` free function (Utilities/Frontmatter.swift),
    /// which the Plugins rail drill-down also uses.
    func parseSkillContent(_ content: String) -> (name: String?, description: String?, metadata: [String: String], body: String) {
        parseFrontmatter(content)
    }
}

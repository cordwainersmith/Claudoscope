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

        return SkillEntry(
            name: parsed.name ?? name,
            displayName: pluginName != nil ? "\(parsed.name ?? name) (\(pluginName!))" : (parsed.name ?? name),
            description: parsed.description,
            metadata: parsed.metadata,
            body: parsed.body,
            sizeBytes: sizeBytes
        )
    }

    /// Parse a SKILL.md file, extracting frontmatter metadata and body content.
    func parseSkillContent(_ content: String) -> (name: String?, description: String?, metadata: [String: String], body: String) {
        let lines = content.components(separatedBy: "\n")
        var name: String?
        var description: String?
        var metadata: [String: String] = [:]
        var bodyStartIndex = 0
        var inFrontmatter = true
        var currentKey: String?
        var currentValue: String?

        func flushCurrentKey() {
            if let key = currentKey, let value = currentValue {
                let trimmedValue = value.trimmingCharacters(in: .whitespaces)
                switch key {
                case "name": name = trimmedValue
                case "description": description = trimmedValue
                default: metadata[key] = trimmedValue
                }
            }
            currentKey = nil
            currentValue = nil
        }

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            guard inFrontmatter else { break }

            // End-of-frontmatter marker
            if trimmed == "---" {
                flushCurrentKey()
                bodyStartIndex = index + 1
                inFrontmatter = false
                continue
            }

            // Empty line ends frontmatter
            if trimmed.isEmpty {
                flushCurrentKey()
                bodyStartIndex = index + 1
                inFrontmatter = false
                continue
            }

            // Check for "key: value" pattern (key must start at column 0 or be a simple word)
            if let colonRange = trimmed.range(of: ":"),
               colonRange.lowerBound != trimmed.startIndex {
                let key = String(trimmed[trimmed.startIndex..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                // Only treat as frontmatter if key is a simple identifier (no spaces, no markdown)
                if !key.isEmpty && key.range(of: "^[a-zA-Z_][a-zA-Z0-9_-]*$", options: .regularExpression) != nil {
                    flushCurrentKey()
                    let value = String(trimmed[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    currentKey = key
                    currentValue = value
                    bodyStartIndex = index + 1
                    continue
                }
            }

            // Indented continuation of previous value (for multi-line args, etc.)
            if currentKey != nil && (line.hasPrefix("  ") || line.hasPrefix("\t")) {
                currentValue = (currentValue ?? "") + "\n" + trimmed
                bodyStartIndex = index + 1
                continue
            }

            // Line doesn't match frontmatter pattern, start body here
            flushCurrentKey()
            inFrontmatter = false
            bodyStartIndex = index
        }

        flushCurrentKey()

        let bodyLines = Array(lines[bodyStartIndex...])
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        return (name, description, metadata, body)
    }
}

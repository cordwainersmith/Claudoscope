import Foundation

extension ConfigLinterService {

    // MARK: - Skills Linting

    func lintSkills(skillsDir: URL) -> (results: [LintResult], descriptions: [String]) {
        var results: [LintResult] = []
        var descriptions: [String] = []

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: skillsDir.path, isDirectory: &isDir), isDir.boolValue else {
            return (results, descriptions)
        }

        guard let skillDirs = try? fm.contentsOfDirectory(at: skillsDir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return (results, descriptions)
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
        }

        return (results, descriptions)
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

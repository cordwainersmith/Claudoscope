import Foundation
import Darwin

actor ConfigLinterService {
    private let fm = FileManager.default

    // Session health check thresholds
    private static let sesHighCostThreshold: Double = 25.0
    private static let sesHighMessageThreshold = 200
    private static let sesHighTokenThreshold = 5_000_000
    private static let sesStaleDaysThreshold = 7
    private static let sesStaleMinMessages = 50
    private static let sesMaxResults = 10
    private static let sesLookbackDays = 30

    // Directories to skip when walking file trees
    private let skipDirs: Set<String> = [
        ".git", "node_modules", ".build", ".swiftpm", ".Trash",
        "Pods", "DerivedData", "vendor", "__pycache__", ".tox"
    ]

    // MARK: - Public API

    func lint(projectRoot: String?, globalClaudeDir: URL) async -> [LintResult] {
        var results: [LintResult] = []
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path

        // Discover and lint CLAUDE.md files
        let claudeMdFiles = discoverClaudeMdFiles(projectRoot: projectRoot, globalDir: globalClaudeDir)
        for file in claudeMdFiles {
            results.append(contentsOf: lintClaudeMd(file, projectRoot: projectRoot, homeDir: homeDir))
        }

        // Check for .claude/commands/ deprecation
        if let root = projectRoot {
            results.append(contentsOf: checkCommandsDeprecation(projectRoot: root))
        }

        // Check @import depth
        if let root = projectRoot {
            results.append(contentsOf: checkImportDepth(projectRoot: root, claudeMdFiles: claudeMdFiles, homeDir: homeDir))
        }

        // Discover and lint rules
        if let root = projectRoot {
            let rulesDir = URL(fileURLWithPath: root).appendingPathComponent(".claude/rules")
            results.append(contentsOf: lintRules(rulesDir: rulesDir, projectRoot: root))
        }

        // Discover and lint skills
        var allSkillDescriptions: [String] = []

        // Project skills
        if let root = projectRoot {
            let skillsDir = URL(fileURLWithPath: root).appendingPathComponent(".claude/skills")
            let (skillResults, descs) = lintSkills(skillsDir: skillsDir)
            results.append(contentsOf: skillResults)
            allSkillDescriptions.append(contentsOf: descs)
        }

        // Global skills
        let globalSkillsDir = globalClaudeDir.appendingPathComponent("skills")
        let (globalSkillResults, globalDescs) = lintSkills(skillsDir: globalSkillsDir)
        results.append(contentsOf: globalSkillResults)
        allSkillDescriptions.append(contentsOf: globalDescs)

        // SKL_AGG: aggregate description budget
        let totalDescChars = allSkillDescriptions.reduce(0) { $0 + $1.count }
        if totalDescChars > 16000 {
            results.append(LintResult(
                severity: .warning,
                checkId: .SKL_AGG,
                filePath: ".claude/skills/",
                message: "Aggregate skill descriptions total \(totalDescChars) chars, exceeding the 16,000-char context budget.",
                fix: "Shorten skill descriptions or disable unused skills.",
                displayPath: "All skills"
            ))
        }

        // Cross-cutting token estimation
        results.append(contentsOf: crossCuttingChecks(projectRoot: projectRoot, globalDir: globalClaudeDir, claudeMdFiles: claudeMdFiles))

        // Sort by severity (errors first)
        results.sort { $0.severity < $1.severity }
        return results
    }

    // MARK: - CLAUDE.md Discovery

    private func discoverClaudeMdFiles(projectRoot: String?, globalDir: URL) -> [URL] {
        var files: [URL] = []

        // Global CLAUDE.md
        let globalClaudeMd = globalDir.appendingPathComponent("CLAUDE.md")
        if fm.fileExists(atPath: globalClaudeMd.path) {
            files.append(globalClaudeMd)
        }

        guard let root = projectRoot else { return files }

        let rootURL = URL(fileURLWithPath: root)

        // Project root CLAUDE.md
        let rootClaudeMd = rootURL.appendingPathComponent("CLAUDE.md")
        if fm.fileExists(atPath: rootClaudeMd.path) {
            files.append(rootClaudeMd)
        }

        // .claude/CLAUDE.md
        let dotClaudeMd = rootURL.appendingPathComponent(".claude/CLAUDE.md")
        if fm.fileExists(atPath: dotClaudeMd.path) {
            files.append(dotClaudeMd)
        }

        // Recursively find subdirectory CLAUDE.md files (depth limit 3, skip common dirs)
        files.append(contentsOf: findClaudeMdRecursive(in: rootURL, currentDepth: 0, maxDepth: 3, exclude: [rootClaudeMd.path, dotClaudeMd.path]))

        return files
    }

    private func findClaudeMdRecursive(in directory: URL, currentDepth: Int, maxDepth: Int, exclude: [String]) -> [URL] {
        guard currentDepth < maxDepth else { return [] }
        var found: [URL] = []

        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return found
        }

        for entry in entries {
            let name = entry.lastPathComponent
            if skipDirs.contains(name) { continue }

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }

            // Skip .claude directory since we already check .claude/CLAUDE.md explicitly
            if name == ".claude" { continue }

            let candidate = entry.appendingPathComponent("CLAUDE.md")
            if fm.fileExists(atPath: candidate.path) && !exclude.contains(candidate.path) {
                found.append(candidate)
            }

            found.append(contentsOf: findClaudeMdRecursive(in: entry, currentDepth: currentDepth + 1, maxDepth: maxDepth, exclude: exclude))
        }

        return found
    }

    // MARK: - CLAUDE.md Linting

    private func makeDisplayPath(for filePath: String, projectRoot: String?, homeDir: String) -> String {
        if let root = projectRoot, filePath.hasPrefix(root) {
            let relative = String(filePath.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return relative.isEmpty ? (filePath as NSString).lastPathComponent : relative
        }
        if filePath.hasPrefix(homeDir) {
            return "~" + String(filePath.dropFirst(homeDir.count))
        }
        return (filePath as NSString).lastPathComponent
    }

    private func lintClaudeMd(_ fileURL: URL, projectRoot: String?, homeDir: String) -> [LintResult] {
        var results: [LintResult] = []
        let path = fileURL.path
        let display = makeDisplayPath(for: path, projectRoot: projectRoot, homeDir: homeDir)

        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return results
        }

        let lines = content.components(separatedBy: "\n")
        let lineCount = lines.count

        // CMD001: >200 lines
        if lineCount > 200 {
            results.append(LintResult(
                severity: .warning,
                checkId: .CMD001,
                filePath: path,
                message: "CLAUDE.md has \(lineCount) lines, exceeding 200. Large files may dilute instruction priority.",
                fix: "Split into focused .claude/rules/ files with glob-scoped paths.",
                displayPath: display
            ))
        }

        // CMD002: >100 lines without rules directory
        if lineCount > 100 {
            let parentDir = fileURL.deletingLastPathComponent()
            // Check if there's a .claude/rules/ directory relative to where this CLAUDE.md lives
            let rulesDir: URL
            if parentDir.lastPathComponent == ".claude" {
                rulesDir = parentDir.appendingPathComponent("rules")
            } else {
                rulesDir = parentDir.appendingPathComponent(".claude/rules")
            }
            var isDir: ObjCBool = false
            let hasRules = fm.fileExists(atPath: rulesDir.path, isDirectory: &isDir) && isDir.boolValue
            if !hasRules {
                results.append(LintResult(
                    severity: .info,
                    checkId: .CMD002,
                    filePath: path,
                    message: "CLAUDE.md has \(lineCount) lines but no .claude/rules/ directory exists. Rules files let you scope instructions to specific file types.",
                    fix: "Create .claude/rules/ and move file-type-specific instructions into scoped rule files.",
                    displayPath: display
                ))
            }
        }

        // CMD003: file-type patterns mentioned 3+ times
        let fileTypePattern = "\\*\\.[a-zA-Z0-9]+"
        var extensionCounts: [String: Int] = [:]
        for line in lines {
            if let range = line.range(of: fileTypePattern, options: .regularExpression) {
                var searchStart = line.startIndex
                while let matchRange = line.range(of: fileTypePattern, options: .regularExpression, range: searchStart..<line.endIndex) {
                    let ext = String(line[matchRange])
                    extensionCounts[ext, default: 0] += 1
                    searchStart = matchRange.upperBound
                }
            }
        }
        let frequentExtensions = extensionCounts.filter { $0.value >= 3 }.map(\.key).sorted()
        if !frequentExtensions.isEmpty {
            results.append(LintResult(
                severity: .warning,
                checkId: .CMD003,
                filePath: path,
                message: "File-type patterns appear frequently: \(frequentExtensions.joined(separator: ", ")). These instructions may work better as scoped rules.",
                fix: "Move file-type-specific instructions into .claude/rules/ files with 'paths' frontmatter targeting those extensions.",
                displayPath: display
            ))
        }

        // CMD006: unclosed code blocks (odd number of ``` fences)
        var fenceCount = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                fenceCount += 1
            }
        }
        if fenceCount % 2 != 0 {
            results.append(LintResult(
                severity: .error,
                checkId: .CMD006,
                filePath: path,
                message: "Unclosed code block detected (\(fenceCount) fence markers found, expected even count). This can cause Claude to misparse instructions.",
                fix: "Add a closing ``` fence to balance all code blocks.",
                displayPath: display
            ))
        }

        return results
    }

    // MARK: - Commands Deprecation

    private func checkCommandsDeprecation(projectRoot: String) -> [LintResult] {
        let commandsDir = URL(fileURLWithPath: projectRoot).appendingPathComponent(".claude/commands")
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: commandsDir.path, isDirectory: &isDir), isDir.boolValue {
            return [LintResult(
                severity: .warning,
                checkId: .CMD_DEPRECATE,
                filePath: commandsDir.path,
                message: ".claude/commands/ directory exists. Custom commands have been superseded by skills in recent Claude Code versions.",
                fix: "Migrate commands to .claude/skills/ directories with SKILL.md files.",
                displayPath: ".claude/commands/"
            )]
        }
        return []
    }

    // MARK: - @import Chain Depth

    private func checkImportDepth(projectRoot: String, claudeMdFiles: [URL], homeDir: String) -> [LintResult] {
        var results: [LintResult] = []

        for file in claudeMdFiles {
            let depth = measureImportDepth(from: file, visited: [], maxHops: 6)
            if depth > 5 {
                let display = makeDisplayPath(for: file.path, projectRoot: projectRoot, homeDir: homeDir)
                results.append(LintResult(
                    severity: .warning,
                    checkId: .CMD_IMPORT,
                    filePath: file.path,
                    message: "@import chain from this file reaches \(depth) hops deep, exceeding the recommended limit of 5.",
                    fix: "Flatten the import chain by consolidating intermediate files or removing unnecessary imports.",
                    displayPath: display
                ))
            }
        }

        return results
    }

    private func measureImportDepth(from fileURL: URL, visited: [String], maxHops: Int) -> Int {
        guard !visited.contains(fileURL.path) else { return 0 }
        guard visited.count < maxHops + 1 else { return visited.count }
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return 0 }

        let lines = content.components(separatedBy: "\n")
        var maxDepth = 0
        let parentDir = fileURL.deletingLastPathComponent()

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Match lines like "@path/to/file" or "@./relative/path"
            guard trimmed.hasPrefix("@") else { continue }
            let importPath = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard !importPath.isEmpty else { continue }
            // Skip lines that look like email addresses or decorators
            if importPath.contains(" ") || importPath.hasPrefix("(") { continue }

            let resolvedURL: URL
            if importPath.hasPrefix("/") {
                resolvedURL = URL(fileURLWithPath: importPath)
            } else {
                resolvedURL = parentDir.appendingPathComponent(importPath).standardized
            }

            guard fm.fileExists(atPath: resolvedURL.path) else { continue }

            var newVisited = visited
            newVisited.append(fileURL.path)
            let depth = measureImportDepth(from: resolvedURL, visited: newVisited, maxHops: maxHops)
            maxDepth = max(maxDepth, depth + 1)
        }

        return maxDepth
    }

    // MARK: - Rules Linting

    private func lintRules(rulesDir: URL, projectRoot: String) -> [LintResult] {
        var results: [LintResult] = []

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: rulesDir.path, isDirectory: &isDir), isDir.boolValue else {
            return results
        }

        guard let ruleFiles = try? fm.contentsOfDirectory(at: rulesDir, includingPropertiesForKeys: nil) else {
            return results
        }

        // Build a file list from project root for glob matching (capped at 1000)
        let projectFileList = collectProjectFiles(root: projectRoot, limit: 1000)

        for ruleFile in ruleFiles {
            guard ruleFile.pathExtension == "md" else { continue }
            guard let content = try? String(contentsOf: ruleFile, encoding: .utf8) else { continue }

            let lines = content.components(separatedBy: "\n")
            let path = ruleFile.path
            let display = ruleFile.lastPathComponent

            // RUL005: rule >100 lines
            if lines.count > 100 {
                results.append(LintResult(
                    severity: .warning,
                    checkId: .RUL005,
                    filePath: path,
                    message: "Rule file has \(lines.count) lines, exceeding 100. Long rules dilute instruction focus.",
                    fix: "Split into multiple focused rule files.",
                    displayPath: display
                ))
            }

            // Parse frontmatter
            let (frontmatter, hasFrontmatter, frontmatterClosed) = parseFrontmatter(lines: lines)

            // RUL001: malformed YAML frontmatter (unclosed --- delimiters)
            if hasFrontmatter && !frontmatterClosed {
                results.append(LintResult(
                    severity: .error,
                    checkId: .RUL001,
                    filePath: path,
                    message: "Malformed YAML frontmatter: opening '---' found but no closing '---' delimiter.",
                    fix: "Add a closing '---' line after the frontmatter fields.",
                    displayPath: display
                ))
            }

            // Check globs from paths field
            if let pathsValue = frontmatter["paths"] {
                let globs = parseGlobList(pathsValue)
                for glob in globs {
                    // RUL002: invalid glob syntax
                    if let syntaxError = validateGlobSyntax(glob) {
                        results.append(LintResult(
                            severity: .error,
                            checkId: .RUL002,
                            filePath: path,
                            message: "Invalid glob syntax in paths: '\(glob)'. \(syntaxError)",
                            fix: "Fix the glob pattern syntax.",
                            displayPath: display
                        ))
                        continue
                    }

                    // RUL003: glob matches no files
                    if !projectFileList.isEmpty {
                        let matched = projectFileList.contains { filePath in
                            fnmatchGlob(pattern: glob, path: filePath)
                        }
                        if !matched {
                            results.append(LintResult(
                                severity: .info,
                                checkId: .RUL003,
                                filePath: path,
                                message: "Glob pattern '\(glob)' does not match any files in the project (sampled \(projectFileList.count) files).",
                                fix: "Verify the glob pattern matches intended files, or remove if no longer needed.",
                                displayPath: display
                            ))
                        }
                    }
                }
            }
        }

        return results
    }

    // MARK: - Frontmatter Parsing

    private func parseFrontmatter(lines: [String]) -> (fields: [String: String], hasFrontmatter: Bool, isClosed: Bool) {
        guard !lines.isEmpty else { return ([:], false, false) }

        let firstTrimmed = lines[0].trimmingCharacters(in: .whitespaces)
        guard firstTrimmed == "---" else { return ([:], false, false) }

        var fields: [String: String] = [:]
        var closed = false

        for i in 1..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                closed = true
                break
            }
            // Parse "key: value"
            if let colonRange = trimmed.range(of: ":") {
                let key = String(trimmed[trimmed.startIndex..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty {
                    fields[key] = value
                }
            }
        }

        return (fields, true, closed)
    }

    private func parseGlobList(_ value: String) -> [String] {
        // Handle YAML list syntax: either comma-separated or bracket-enclosed
        var cleaned = value.trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("[") && cleaned.hasSuffix("]") {
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        return cleaned.split(separator: ",").map { segment in
            var s = segment.trimmingCharacters(in: .whitespaces)
            // Strip surrounding quotes
            if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
                s = String(s.dropFirst().dropLast())
            }
            return s
        }.filter { !$0.isEmpty }
    }

    // MARK: - Glob Validation

    private func validateGlobSyntax(_ glob: String) -> String? {
        // Check for unmatched brackets
        var bracketDepth = 0
        var braceDepth = 0
        for char in glob {
            switch char {
            case "[": bracketDepth += 1
            case "]":
                if bracketDepth > 0 { bracketDepth -= 1 }
                else { return "Unmatched closing bracket ']'." }
            case "{": braceDepth += 1
            case "}":
                if braceDepth > 0 { braceDepth -= 1 }
                else { return "Unmatched closing brace '}'." }
            default: break
            }
        }
        if bracketDepth > 0 { return "Unmatched opening bracket '['." }
        if braceDepth > 0 { return "Unmatched opening brace '{'." }

        // Check for empty pattern
        if glob.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Empty glob pattern."
        }

        return nil
    }

    private func fnmatchGlob(pattern: String, path: String) -> Bool {
        // Use POSIX fnmatch with FNM_PATHNAME for directory separators
        return fnmatch(pattern, path, FNM_PATHNAME) == 0
    }

    // MARK: - Project File Collection

    private func collectProjectFiles(root: String, limit: Int) -> [String] {
        var files: [String] = []
        let rootURL = URL(fileURLWithPath: root)
        collectFilesRecursive(directory: rootURL, rootPath: root, files: &files, limit: limit, depth: 0, maxDepth: 5)
        return files
    }

    private func collectFilesRecursive(directory: URL, rootPath: String, files: inout [String], limit: Int, depth: Int, maxDepth: Int) {
        guard files.count < limit, depth < maxDepth else { return }

        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
            return
        }

        for entry in entries {
            guard files.count < limit else { return }
            let name = entry.lastPathComponent
            if skipDirs.contains(name) || name.hasPrefix(".") { continue }

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                collectFilesRecursive(directory: entry, rootPath: rootPath, files: &files, limit: limit, depth: depth + 1, maxDepth: maxDepth)
            } else {
                // Store path relative to root
                let relativePath = String(entry.path.dropFirst(rootPath.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                files.append(relativePath)
            }
        }
    }

    // MARK: - Skills Linting

    private func lintSkills(skillsDir: URL) -> (results: [LintResult], descriptions: [String]) {
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

    private func parseSkillContent(_ content: String) -> (name: String?, description: String?, body: String) {
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

    private func isValidKebabCase(_ name: String) -> Bool {
        // Must be lowercase alphanumeric with single hyphens, not starting or ending with hyphen
        guard !name.isEmpty else { return false }
        if name.hasPrefix("-") || name.hasSuffix("-") { return false }
        if name.contains("--") { return false }
        // Only lowercase letters, digits, and hyphens
        return name.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil
    }

    // MARK: - Cross-cutting Checks

    private func crossCuttingChecks(projectRoot: String?, globalDir: URL, claudeMdFiles: [URL]) -> [LintResult] {
        var results: [LintResult] = []

        // XCT003: no .claude/ directory at project root
        if let root = projectRoot {
            let dotClaude = URL(fileURLWithPath: root).appendingPathComponent(".claude")
            var isDir: ObjCBool = false
            if !(fm.fileExists(atPath: dotClaude.path, isDirectory: &isDir) && isDir.boolValue) {
                results.append(LintResult(
                    severity: .info,
                    checkId: .XCT003,
                    filePath: root,
                    message: "No .claude/ directory found at the project root. Consider adding one for rules, skills, and other config.",
                    fix: "Create a .claude/ directory to organize rules, skills, and project-specific configuration.",
                    displayPath: "Project config"
                ))
            }
        }

        // Estimate total always-loaded tokens from all CLAUDE.md files + rules + skills
        var totalChars = 0

        // CLAUDE.md files
        for file in claudeMdFiles {
            if let content = try? String(contentsOf: file, encoding: .utf8) {
                totalChars += content.count
            }
        }

        // Rules files (always loaded when matching)
        if let root = projectRoot {
            let rulesDir = URL(fileURLWithPath: root).appendingPathComponent(".claude/rules")
            if let ruleFiles = try? fm.contentsOfDirectory(at: rulesDir, includingPropertiesForKeys: nil) {
                for ruleFile in ruleFiles where ruleFile.pathExtension == "md" {
                    if let content = try? String(contentsOf: ruleFile, encoding: .utf8) {
                        totalChars += content.count
                    }
                }
            }
        }

        // Global rules
        let globalRulesDir = globalDir.appendingPathComponent("rules")
        if let ruleFiles = try? fm.contentsOfDirectory(at: globalRulesDir, includingPropertiesForKeys: nil) {
            for ruleFile in ruleFiles where ruleFile.pathExtension == "md" {
                if let content = try? String(contentsOf: ruleFile, encoding: .utf8) {
                    totalChars += content.count
                }
            }
        }

        let estimatedTokens = totalChars / 4

        // XCT001: total token estimate (always reported)
        results.append(LintResult(
            severity: .info,
            checkId: .XCT001,
            filePath: projectRoot ?? "~/.claude",
            message: "Estimated always-loaded config tokens: ~\(estimatedTokens) (from \(totalChars) chars across CLAUDE.md and rules files).",
            displayPath: "Project config"
        ))

        // XCT002: tokens >5000
        if estimatedTokens > 5000 {
            results.append(LintResult(
                severity: .warning,
                checkId: .XCT002,
                filePath: projectRoot ?? "~/.claude",
                message: "Estimated always-loaded tokens (~\(estimatedTokens)) exceed 5,000. This consumes significant context on every request.",
                fix: "Reduce config size by moving instructions to scoped rules or removing redundant content.",
                displayPath: "Project config"
            ))
        }

        return results
    }

    // MARK: - Session Health Checks

    func lintSessions(_ sessions: [SessionSummary]) -> [LintResult] {
        let now = Date()
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -Self.sesLookbackDays, to: now)!

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let isoFormatterNoFrac = ISO8601DateFormatter()
        isoFormatterNoFrac.formatOptions = [.withInternetDateTime]

        func parseDate(_ str: String) -> Date? {
            isoFormatter.date(from: str) ?? isoFormatterNoFrac.date(from: str)
        }

        var results: [LintResult] = []

        for session in sessions {
            guard session.messageCount > 0 else { continue }
            guard let firstDate = parseDate(session.firstTimestamp), firstDate >= cutoff else { continue }

            let syntheticPath = "sessions/\(session.projectId)/\(session.id)"
            let displayTitle = String(session.title.prefix(60))
            let totalTokens = session.totalInputTokens + session.totalOutputTokens
                + session.totalCacheReadTokens + session.totalCacheCreationTokens
            // Skip sessions with 0 tokens - stale data from UUID dedup bug
            guard totalTokens > 0 else { continue }
            let statsTag = " [$\(String(format: "%.2f", session.estimatedCost)) | \(formatTokenCount(totalTokens)) tokens | \(session.messageCount) msgs]"

            // Priority order: SES001 > SES003 > SES002 > SES004 (emit only one per session)
            if session.estimatedCost > Self.sesHighCostThreshold {
                results.append(LintResult(
                    severity: .warning,
                    checkId: .SES001,
                    filePath: syntheticPath,
                    message: "Session cost $\(String(format: "%.2f", session.estimatedCost)). High-cost sessions often indicate context window saturation, where the model re-reads growing context on every turn, multiplying token spend." + statsTag,
                    fix: "For similar tasks, break work into focused sessions. Use /compact proactively before reaching 60% context utilization.",
                    displayPath: displayTitle
                ))
            } else if totalTokens > Self.sesHighTokenThreshold {
                results.append(LintResult(
                    severity: .warning,
                    checkId: .SES003,
                    filePath: syntheticPath,
                    message: "Session consumed \(formatTokenCount(totalTokens)) tokens. High cumulative token counts signal repeated context re-reads across compaction cycles, increasing cost without proportional value." + statsTag,
                    fix: "Start fresh sessions at natural boundaries (e.g., after finishing a feature). Periodic /compact reduces redundant context re-reads.",
                    displayPath: displayTitle
                ))
            } else if session.messageCount > Self.sesHighMessageThreshold {
                results.append(LintResult(
                    severity: .warning,
                    checkId: .SES002,
                    filePath: syntheticPath,
                    message: "Session has \(session.messageCount) messages. Long conversations degrade instruction-following as earlier context gets compressed or evicted, reducing Claude's ability to recall prior decisions." + statsTag,
                    fix: "Use /compact every 30-45 minutes or after completing each milestone. Use /clear when switching between unrelated tasks.",
                    displayPath: displayTitle
                ))
            } else if let lastDate = parseDate(session.lastTimestamp),
                      session.messageCount > Self.sesStaleMinMessages {
                let daysSince = calendar.dateComponents([.day], from: lastDate, to: now).day ?? 0
                if daysSince > Self.sesStaleDaysThreshold {
                    results.append(LintResult(
                        severity: .info,
                        checkId: .SES004,
                        filePath: syntheticPath,
                        message: "Session idle for \(daysSince) days with \(session.messageCount) messages. Resuming a stale session means Claude rebuilds context from a compressed summary, losing nuance from the original conversation." + statsTag,
                        fix: "Start a fresh session rather than resuming. Use /clear or begin a new Claude Code instance for better results.",
                        displayPath: displayTitle
                    ))
                }
            }
        }

        // Sort by severity (errors first, then warnings, then info), cap at 10
        results.sort { $0.severity < $1.severity }
        if results.count > Self.sesMaxResults {
            results = Array(results.prefix(Self.sesMaxResults))
        }

        return results
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.0fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    // MARK: - Secret Detection

    struct SecretPattern {
        let checkId: LintCheckId
        let name: String
        let regex: NSRegularExpression
        let severity: LintSeverity
        let skipHosts: [String]?
        let secretGroup: Int?
        let entropyThreshold: Double?
        let requiresDigit: Bool

        init(checkId: LintCheckId, name: String, pattern: String, severity: LintSeverity,
             skipHosts: [String]? = nil, secretGroup: Int? = nil,
             entropyThreshold: Double? = nil, requiresDigit: Bool = false,
             caseInsensitive: Bool = false) {
            self.checkId = checkId
            self.name = name
            var opts: NSRegularExpression.Options = []
            if caseInsensitive { opts.insert(.caseInsensitive) }
            self.regex = try! NSRegularExpression(pattern: pattern, options: opts)
            self.severity = severity
            self.skipHosts = skipHosts
            self.secretGroup = secretGroup
            self.entropyThreshold = entropyThreshold
            self.requiresDigit = requiresDigit
        }
    }

    private static let secretPatterns: [SecretPattern] = [
        SecretPattern(
            checkId: .SEC001, name: "Private Key",
            pattern: "-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----",
            severity: .error
        ),
        SecretPattern(
            checkId: .SEC002, name: "AWS Access Key",
            pattern: "(AKIA|ASIA)[A-Z0-9]{16}",
            severity: .error,
            entropyThreshold: 3.0
        ),
        SecretPattern(
            checkId: .SEC003, name: "Authorization Header",
            pattern: "Authorization.*?(Bearer|Basic)\\s+([A-Za-z0-9+/=._-]{20,})",
            severity: .warning,
            secretGroup: 2, entropyThreshold: 3.5, requiresDigit: true
        ),
        SecretPattern(
            checkId: .SEC004, name: "API Key/Token",
            pattern: "(api[_-]?key|api[_-]?token|access[_-]?token)\\s*[:=]\\s*[\"']?([A-Za-z0-9_\\-./+=]{20,})",
            severity: .warning,
            secretGroup: 2, entropyThreshold: 3.5, requiresDigit: true,
            caseInsensitive: true
        ),
        SecretPattern(
            checkId: .SEC005, name: "Password/Secret Literal",
            pattern: "(password|passwd|secret)\\s*[:=]\\s*[\"']([^\"']{12,})[\"']",
            severity: .warning,
            secretGroup: 2, entropyThreshold: 3.0, requiresDigit: true,
            caseInsensitive: true
        ),
        SecretPattern(
            checkId: .SEC006, name: "Connection String",
            pattern: "(mongodb|postgres|mysql|redis|jdbc)[+a-z]*://[^:]+:([^@]+)@",
            severity: .warning,
            skipHosts: ["localhost", "127.0.0.1", "0.0.0.0", "host.docker.internal", "example.com", "db", "database"],
            secretGroup: 2, entropyThreshold: 2.5
        ),
        SecretPattern(
            checkId: .SEC007, name: "Platform Token",
            pattern: "(ghp_[A-Za-z0-9_]{36}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|xox[bps]-[A-Za-z0-9./-]{20,}|npm_[A-Za-z0-9]{36}|sk_live_[A-Za-z0-9]{20,}|AIza[A-Za-z0-9_-]{35})",
            severity: .warning
        ),
    ]

    private static let falsePositiveSubstrings: [String] = [
        "AKIAIOSFODNN7EXAMPLE", "sk_test_", "pk_test_", "your-api-key",
        "<your-", "placeholder", "changeme", "example", "TODO", "xxxxxxxx",
        "0000000000", "abcdefgh", "REPLACE_ME",
        "XXX", "xxx", "REDACTED", "MASKED", "DUMMY", "FAKE", "NONE",
        "null", "undefined", "N/A", "INSERT_", "PASTE_",
        "${", "{{", "<your", "%s", "{0}"
    ]

    private static let conversationalContextPhrases: [String] = [
        "in the .env", "set your", "configure the", "stored in",
        "replace with", "environment variable", "add to your",
        "put your", ".env file"
    ]

    static func shannonEntropy(_ s: String) -> Double {
        guard !s.isEmpty else { return 0.0 }
        var freq: [Character: Int] = [:]
        for c in s { freq[c, default: 0] += 1 }
        let length = Double(s.count)
        var entropy = 0.0
        for count in freq.values {
            let p = Double(count) / length
            entropy -= p * log2(p)
        }
        return entropy
    }

    static func maskSecret(_ value: String) -> String {
        guard value.count >= 8 else { return "****" }
        let prefix = String(value.prefix(4))
        let suffix = String(value.suffix(4))
        return "\(prefix)****\(suffix)"
    }

    /// Truncate and clean a JSONL line for display as context
    static func sanitizeContextLine(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 200 { return trimmed }
        return String(trimmed.prefix(200)) + "..."
    }

    struct SecretFinding: Sendable {
        let checkId: LintCheckId
        let patternName: String
        let matchedText: String
        let lineIndex: Int?
    }

    func scanLinesForSecrets(_ lines: [String]) -> [SecretFinding] {
        var findings: [SecretFinding] = []
        for (lineIndex, line) in lines.enumerated() {
            guard line.count <= 200_000 else { continue }
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)

            for pattern in Self.secretPatterns {
                guard let match = pattern.regex.firstMatch(in: line, options: [], range: range) else { continue }
                let matchedText = nsLine.substring(with: match.range)

                // 1. Extract the secret value via capture group (or full match)
                let secretValue: String
                if let group = pattern.secretGroup,
                   group < match.numberOfRanges,
                   match.range(at: group).location != NSNotFound {
                    secretValue = nsLine.substring(with: match.range(at: group))
                } else {
                    secretValue = matchedText
                }

                let lowerValue = secretValue.lowercased()
                let lowerLine = line.lowercased()

                // 2. Check false positive substrings against value and full line
                if Self.falsePositiveSubstrings.contains(where: { lowerValue.contains($0.lowercased()) || lowerLine.contains($0.lowercased()) }) {
                    continue
                }

                // 3. Check conversational context phrases against full line
                if Self.conversationalContextPhrases.contains(where: { lowerLine.contains($0.lowercased()) }) {
                    continue
                }

                // 4. Check unique character count (<= 3 unique chars -> skip)
                let uniqueChars = Set(secretValue)
                if uniqueChars.count <= 3 {
                    continue
                }

                // 5. Check hasDigit requirement (SEC003/004/005)
                if pattern.requiresDigit && !secretValue.contains(where: { $0.isNumber }) {
                    continue
                }

                // 6. Shannon entropy check
                if let threshold = pattern.entropyThreshold {
                    let entropy = Self.shannonEntropy(secretValue)
                    if entropy < threshold {
                        continue
                    }
                }

                // 7. SEC006: skip local/example hosts
                if let skipHosts = pattern.skipHosts {
                    if skipHosts.contains(where: { lowerLine.contains($0) }) {
                        continue
                    }
                }

                findings.append(SecretFinding(
                    checkId: pattern.checkId,
                    patternName: pattern.name,
                    matchedText: matchedText,
                    lineIndex: lineIndex
                ))
            }
        }
        return findings
    }

    private static let secMaxPerPatternPerFile = 3
    private static let secMaxTotal = 20
    private static let secLookbackDays = 30
    private static let secMinMessages = 10

    func lintSessionSecrets(_ sessions: [SessionSummary], claudeDir: URL) -> [LintResult] {
        let now = Date()
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -Self.secLookbackDays, to: now)!

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFormatterNoFrac = ISO8601DateFormatter()
        isoFormatterNoFrac.formatOptions = [.withInternetDateTime]

        func parseDate(_ str: String) -> Date? {
            isoFormatter.date(from: str) ?? isoFormatterNoFrac.date(from: str)
        }

        var results: [LintResult] = []

        for session in sessions {
            guard session.messageCount > Self.secMinMessages else { continue }
            guard let firstDate = parseDate(session.firstTimestamp), firstDate >= cutoff else { continue }

            // Build file paths for this session
            let projectDir = claudeDir
                .appendingPathComponent("projects")
                .appendingPathComponent(session.projectId)
            let mainFile = projectDir.appendingPathComponent("\(session.id).jsonl")

            var filesToScan: [URL] = []
            if fm.fileExists(atPath: mainFile.path) {
                filesToScan.append(mainFile)
            }

            // Check for subagent files
            let subagentDir = projectDir
                .appendingPathComponent(session.id)
                .appendingPathComponent("subagents")
            if let subagentFiles = try? fm.contentsOfDirectory(at: subagentDir, includingPropertiesForKeys: nil) {
                for file in subagentFiles where file.pathExtension == "jsonl" {
                    filesToScan.append(file)
                }
            }

            let syntheticPath = "sessions/\(session.projectId)/\(session.id)"
            let displayTitle = String(session.title.prefix(60))

            // Track per-pattern counts for this session's files
            var patternCounts: [LintCheckId: Int] = [:]

            for fileURL in filesToScan {
                guard let data = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                let lines = data.components(separatedBy: "\n")

                let findings = scanLinesForSecrets(lines)
                for finding in findings {
                    let count = patternCounts[finding.checkId, default: 0]
                    guard count < Self.secMaxPerPatternPerFile else { continue }
                    guard results.count < Self.secMaxTotal else { return results }

                    patternCounts[finding.checkId] = count + 1
                    let masked = Self.maskSecret(finding.matchedText)

                    // Capture context: the line before and the line containing the secret
                    var context: [String] = []
                    if let idx = finding.lineIndex {
                        if idx > 0 {
                            context.append(Self.sanitizeContextLine(lines[idx - 1]))
                        }
                        context.append(Self.sanitizeContextLine(lines[idx]))
                    }

                    results.append(LintResult(
                        severity: Self.secretPatterns.first(where: { $0.checkId == finding.checkId })?.severity ?? .warning,
                        checkId: finding.checkId,
                        filePath: syntheticPath,
                        message: "\(finding.patternName) detected: \(masked)",
                        fix: "Rotate this credential immediately. Avoid pasting secrets into Claude Code sessions. Use environment variables or secret managers instead.",
                        displayPath: displayTitle,
                        contextLines: context.isEmpty ? nil : context,
                        unmaskedSecret: finding.matchedText
                    ))
                }
            }

            if results.count >= Self.secMaxTotal { break }
        }

        results.sort { $0.severity < $1.severity }
        return results
    }
}

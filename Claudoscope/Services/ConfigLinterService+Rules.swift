import Foundation
import Darwin

extension ConfigLinterService {

    // MARK: - Rules Linting

    func lintRules(rulesDir: URL, projectRoot: String) -> [LintResult] {
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

    func parseFrontmatter(lines: [String]) -> (fields: [String: String], hasFrontmatter: Bool, isClosed: Bool) {
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

    func parseGlobList(_ value: String) -> [String] {
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

    func validateGlobSyntax(_ glob: String) -> String? {
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

    func fnmatchGlob(pattern: String, path: String) -> Bool {
        // Use POSIX fnmatch with FNM_PATHNAME for directory separators
        return fnmatch(pattern, path, FNM_PATHNAME) == 0
    }

    // MARK: - Project File Collection

    func collectProjectFiles(root: String, limit: Int) -> [String] {
        var files: [String] = []
        let rootURL = URL(fileURLWithPath: root)
        collectFilesRecursive(directory: rootURL, rootPath: root, files: &files, limit: limit, depth: 0, maxDepth: 5)
        return files
    }

    func collectFilesRecursive(directory: URL, rootPath: String, files: inout [String], limit: Int, depth: Int, maxDepth: Int) {
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
}

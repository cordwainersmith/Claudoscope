import Foundation

extension ConfigLinterService {

    // MARK: - Cross-cutting Checks

    func crossCuttingChecks(projectRoot: String?, globalDir: URL, claudeMdFiles: [URL]) -> [LintResult] {
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
}

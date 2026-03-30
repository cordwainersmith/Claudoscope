import Foundation
import Darwin

actor ConfigLinterService {
    let fm = FileManager.default

    // Session health check thresholds
    static let sesHighCostThreshold: Double = 25.0
    static let sesHighMessageThreshold = 200
    static let sesHighCompactionThreshold = 3
    static let sesHighTokenThreshold = 5_000_000
    static let sesStaleDaysThreshold = 7
    static let sesStaleMinMessages = 50
    static let sesMaxResults = 10
    static let sesLookbackDays = 30

    // Directories to skip when walking file trees
    let skipDirs: Set<String> = [
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

        // Config health checks (CFG001-CFG006)
        let projectRootURL = projectRoot.map { URL(fileURLWithPath: $0) }
        results.append(contentsOf: lintConfig(globalClaudeDir: globalClaudeDir, projectRoot: projectRootURL))

        // Sort by severity (errors first)
        results.sort { $0.severity < $1.severity }
        return results
    }

    // MARK: - Shared Helpers

    func makeDisplayPath(for filePath: String, projectRoot: String?, homeDir: String) -> String {
        if let root = projectRoot, filePath.hasPrefix(root) {
            let relative = String(filePath.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return relative.isEmpty ? (filePath as NSString).lastPathComponent : relative
        }
        if filePath.hasPrefix(homeDir) {
            return "~" + String(filePath.dropFirst(homeDir.count))
        }
        return (filePath as NSString).lastPathComponent
    }

    func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.0fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}

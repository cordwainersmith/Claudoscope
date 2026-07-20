import Foundation
import MCP

extension McpToolHandlers {
    // MARK: - lint_config

    struct LintFinding: Encodable {
        // Deliberately no unmaskedSecret and no contextLines: raw secret
        // material must never leave the app through this tool.
        let severity: String
        let checkId: String
        let path: String
        let line: Int?
        let message: String
        let fix: String?
    }

    struct LintResponse: Encodable {
        struct Summary: Encodable {
            let errors: Int
            let warnings: Int
            let infos: Int
            let healthScore: Double
        }
        let project: String?
        let summary: Summary
        let findings: [LintFinding]
    }

    /// Fresh on-demand lint. Mirrors the pure sequence inside
    /// SessionStore.runConfigLint(projectId:) without its progressive UI
    /// updates; keep the two in sync when lint phases change.
    static func lintConfig(_ arguments: [String: Value]?, _ context: McpToolContext) async throws -> CallTool.Result {
        let snapshot = await context.snapshot()
        let project = try await optionalProject(arguments, snapshot: snapshot, configService: context.configService)

        let sessions: [SessionSummary]
        if let project {
            sessions = snapshot.sessionsByProject[project.id] ?? []
        } else {
            sessions = snapshot.sessionsByProject.values.flatMap { $0 }
        }
        let projectRoot: String?
        if let project {
            projectRoot = await context.configService.decodeProjectPath(project.id)
        } else {
            projectRoot = nil
        }

        var results = await context.linterService.lint(projectRoot: projectRoot, globalClaudeDir: context.claudeDir)
        results.append(contentsOf: await context.linterService.lintSessions(sessions))
        if let project, let projectRoot, snapshot.canonOptedInProjectIds.contains(project.id) {
            results.append(contentsOf: await context.linterService.lintCanon(
                projectRoot: projectRoot,
                bundledProtocolVersion: snapshot.bundledCanonProtocolVersion
            ))
        }
        let secretResults = await context.linterService.lintSessionSecrets(sessions, claudeDir: context.claudeDir)
        results.append(contentsOf: secretResults)
        if results.contains(where: { $0.checkId == .CFG006 }) && !secretResults.isEmpty {
            results.append(LintResult(
                severity: .warning,
                checkId: .SEC008,
                filePath: "settings.json",
                message: "\(secretResults.count) credential pattern(s) found in session data while CLAUDE_CODE_SUBPROCESS_ENV_SCRUB is not set. Credentials may leak via Bash tool, hooks, or MCP servers.",
                fix: "Add CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 to settings.json env section to prevent credential leakage into subprocess environments.",
                displayPath: "settings.json"
            ))
        }
        results.sort { $0.severity < $1.severity }

        let summary = LintSummary.from(results: results)
        return encodeJSON(LintResponse(
            project: project?.name,
            summary: .init(
                errors: summary.errorCount,
                warnings: summary.warningCount,
                infos: summary.infoCount,
                healthScore: round4(summary.healthScore)
            ),
            findings: results.map(lintFinding)
        ))
    }

    static func lintFinding(_ result: LintResult) -> LintFinding {
        LintFinding(
            severity: result.severity.rawValue,
            checkId: result.checkId.rawValue,
            path: result.displayPath ?? result.filePath,
            line: result.line,
            message: result.message,
            fix: result.fix
        )
    }

    // MARK: - get_config

    struct ConfigResponse: Encodable {
        struct Command: Encodable {
            let name: String
            let description: String?
            let sizeBytes: Int
            let allowedTools: [String]?
            let disallowedTools: [String]?
        }
        struct Skill: Encodable {
            let name: String
            let description: String?
            let sizeBytes: Int
            let allowedTools: [String]?
            let disallowedTools: [String]?
        }
        struct McpServer: Encodable {
            let name: String
            let command: String?
            let args: [String]
            let url: String?
            let envKeys: [String: String]
            let level: String?
            let authStatus: String
        }
        struct Memory: Encodable {
            let label: String
            let scope: String
            let path: String
            let sizeBytes: Int?
        }
        struct Hook: Encodable {
            let event: String
            let matcher: String
            let commands: [String]
            let source: String
        }
        struct Plugin: Encodable {
            let name: String
            let marketplace: String?
            let enabled: Bool
            let components: [String]?
        }
        var commands: [Command]?
        var skills: [Skill]?
        var mcpServers: [McpServer]?
        var memory: [Memory]?
        var hooks: [Hook]?
        var plugins: [Plugin]?
    }

    static func getConfig(_ arguments: [String: Value]?, _ context: McpToolContext) async throws -> CallTool.Result {
        let snapshot = await context.snapshot()
        let project = try await optionalProject(arguments, snapshot: snapshot, configService: context.configService)
        let projectPath = project == nil ? nil : await context.configService.decodeProjectPath(project!.id)

        let validKinds = ["commands", "skills", "mcp_servers", "memory", "hooks", "plugins"]
        let kind = string(arguments, "kind")
        if let kind, !validKinds.contains(kind) {
            throw McpToolError(message: "Invalid kind \"\(kind)\"; use one of \(validKinds.joined(separator: ", "))")
        }
        func wants(_ candidate: String) -> Bool { kind == nil || kind == candidate }

        var response = ConfigResponse()
        if wants("commands") {
            response.commands = await context.configService.loadCommands().map {
                .init(
                    name: $0.name, description: $0.description, sizeBytes: $0.sizeBytes,
                    allowedTools: $0.allowedTools, disallowedTools: $0.disallowedTools
                )
            }
        }
        if wants("skills") {
            response.skills = await context.configService.loadSkills().map {
                .init(
                    name: $0.displayName, description: $0.description, sizeBytes: $0.sizeBytes,
                    allowedTools: $0.allowedTools, disallowedTools: $0.disallowedTools
                )
            }
        }
        if wants("mcp_servers") {
            response.mcpServers = await context.configService.loadMcpServers(projectPath: projectPath).map { entry in
                .init(
                    name: entry.name,
                    command: entry.command,
                    args: entry.args,
                    url: entry.url,
                    // Env values may be credentials; keys survive, values never do.
                    envKeys: entry.env.mapValues { _ in "***" },
                    level: entry.level,
                    authStatus: String(describing: entry.authStatus)
                )
            }
        }
        if wants("memory") {
            response.memory = await context.configService.loadMemoryFiles(projectId: project?.id).map {
                .init(label: $0.label, scope: $0.sublabel, path: $0.path, sizeBytes: $0.sizeBytes)
            }
        }
        if wants("hooks") {
            let projectPaths = snapshot.projects.map { (name: $0.name, path: $0.path) }
            response.hooks = await context.configService.loadHooks(projectPaths: projectPaths).flatMap { group in
                group.rules.map { rule in
                    ConfigResponse.Hook(
                        event: group.event,
                        matcher: rule.matcher,
                        commands: rule.hooks.map(\.command),
                        source: rule.source.label
                    )
                }
            }
        }
        if wants("plugins") {
            response.plugins = await context.configService.loadPlugins().map {
                .init(name: $0.fullName, marketplace: $0.marketplace, enabled: $0.enabled, components: $0.components)
            }
        }
        return encodeJSON(response)
    }

    // MARK: - get_canon

    struct CanonRecordEntry: Encodable {
        let title: String
        let kind: String?
        let date: String?
        let status: String
        let supersededBy: String?
        let body: String
    }

    struct CanonResponse: Encodable {
        let project: String
        let records: [CanonRecordEntry]
        let protocolInstalled: Bool
        let protocolVersion: Int?
        let dataPath: String?
        let rulePath: String?
    }

    struct CanonProjectEntry: Encodable {
        let project: String
        let projectId: String
        let detectedOnDisk: Bool
        let optedIn: Bool
    }

    static func getCanon(_ arguments: [String: Value]?, _ context: McpToolContext) async throws -> CallTool.Result {
        let snapshot = await context.snapshot()
        let project = try await optionalProject(arguments, snapshot: snapshot, configService: context.configService)

        guard let project else {
            let detected = await context.configService.detectCanonProjects(projectIds: snapshot.projects.map(\.id))
            let entries = snapshot.projects
                .filter { detected.contains($0.id) || snapshot.canonOptedInProjectIds.contains($0.id) }
                .map {
                    CanonProjectEntry(
                        project: $0.name,
                        projectId: $0.id,
                        detectedOnDisk: detected.contains($0.id),
                        optedIn: snapshot.canonOptedInProjectIds.contains($0.id)
                    )
                }
            return encodeJSON(entries)
        }

        let data = await context.configService.loadCanon(projectId: project.id)
        let records = data.records.map { record -> CanonRecordEntry in
            let status: String
            var supersededBy: String?
            switch record.status {
            case .canon:
                status = "canon"
            case .superseded(let by):
                status = "non-canon"
                supersededBy = by
            case .nonCanonNoPointer:
                status = "non-canon"
            case .unknown(let raw):
                status = raw
            }
            return CanonRecordEntry(
                title: record.title,
                kind: record.kind?.rawValue,
                date: record.dateString,
                status: status,
                supersededBy: supersededBy,
                body: record.body
            )
        }
        return encodeJSON(CanonResponse(
            project: project.name,
            records: records,
            protocolInstalled: data.protocolInstalled,
            protocolVersion: data.protocolVersion,
            dataPath: data.dataPath,
            rulePath: data.rulePath
        ))
    }
}

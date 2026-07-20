import Foundation
import MCP

/// Read-only tool handlers for the embedded MCP server. Each handler snapshots
/// SessionStore state via the context closure and/or calls the stateless
/// config/linter/plans actors directly.
enum McpToolHandlers {
    static func dispatch(name: String, arguments: [String: Value]?, context: McpToolContext) async -> CallTool.Result {
        do {
            switch name {
            case "get_usage": return try await getUsage(arguments, context)
            case "list_projects": return try await listProjects(arguments, context)
            case "list_sessions": return try await listSessions(arguments, context)
            case "search_sessions": return try await searchSessions(arguments, context)
            case "get_session": return try await getSession(arguments, context)
            case "lint_config": return try await lintConfig(arguments, context)
            case "get_config": return try await getConfig(arguments, context)
            case "list_plans": return try await listPlans(arguments, context)
            case "get_canon": return try await getCanon(arguments, context)
            default:
                return errorResult("Unknown tool: \(name)")
            }
        } catch let error as McpToolError {
            return errorResult(error.message)
        } catch {
            return errorResult("Internal error: \(error)")
        }
    }

    // MARK: - Shared plumbing

    struct McpToolError: Error {
        let message: String
    }

    static func string(_ arguments: [String: Value]?, _ key: String) -> String? {
        arguments?[key]?.stringValue
    }

    static func int(_ arguments: [String: Value]?, _ key: String) -> Int? {
        arguments?[key]?.intValue
    }

    static func bool(_ arguments: [String: Value]?, _ key: String) -> Bool? {
        arguments?[key]?.boolValue
    }

    static func limit(_ arguments: [String: Value]?, default defaultLimit: Int = 25) -> Int {
        min(max(int(arguments, "limit") ?? defaultLimit, 1), 200)
    }

    static func encodeJSON<T: Encodable>(_ value: T) -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return errorResult("Failed to encode response")
        }
        return CallTool.Result(content: [.text(text)])
    }

    static func errorResult(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(message)], isError: true)
    }

    static func round4(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }

    /// Match a project by exact id, then case-insensitive display name, then
    /// real filesystem path. Throws with candidates on no match.
    static func resolveProject(
        _ query: String,
        snapshot: McpStoreSnapshot,
        configService: ConfigService
    ) async throws -> Project {
        if let byId = snapshot.projects.first(where: { $0.id == query }) {
            return byId
        }
        let lowered = query.lowercased()
        let byName = snapshot.projects.filter { $0.name.lowercased() == lowered }
        if byName.count == 1 { return byName[0] }
        if byName.count > 1 {
            throw McpToolError(message: "Ambiguous project name \"\(query)\"; use one of these ids: \(byName.map(\.id).joined(separator: ", "))")
        }
        let normalizedQuery = (query as NSString).expandingTildeInPath
        for project in snapshot.projects {
            if let real = await configService.decodeProjectPath(project.id), real == normalizedQuery {
                return project
            }
        }
        let known = snapshot.projects.map(\.name).sorted().joined(separator: ", ")
        throw McpToolError(message: "Unknown project \"\(query)\". Known projects: \(known)")
    }

    static func optionalProject(
        _ arguments: [String: Value]?,
        snapshot: McpStoreSnapshot,
        configService: ConfigService
    ) async throws -> Project? {
        guard let query = string(arguments, "project"), !query.isEmpty else { return nil }
        return try await resolveProject(query, snapshot: snapshot, configService: configService)
    }

    static func sessionsWithProjects(
        _ snapshot: McpStoreSnapshot,
        projectId: String?
    ) -> [(session: SessionSummary, project: Project)] {
        snapshot.projects
            .filter { projectId == nil || $0.id == projectId }
            .flatMap { project in
                (snapshot.sessionsByProject[project.id] ?? []).map { ($0, project) }
            }
    }

    /// Maps the period/from/to params through AnalyticsTimeRange so window
    /// semantics (half-open local-day) match the dashboard exactly.
    static func periodRange(_ arguments: [String: Value]?) throws -> (from: Date?, to: Date?) {
        let period = string(arguments, "period") ?? "all"
        let range: AnalyticsTimeRange
        switch period {
        case "today": range = .today
        case "7d": range = .sevenDays
        case "30d": range = .thirtyDays
        case "all": range = .all
        case "custom": range = .custom
        default:
            throw McpToolError(message: "Invalid period \"\(period)\"; use today, 7d, 30d, all, or custom")
        }
        var customFrom = Date()
        var customTo = Date()
        if range == .custom {
            guard let fromString = string(arguments, "from"), let fromDate = parseDay(fromString) else {
                throw McpToolError(message: "period=custom requires from (YYYY-MM-DD)")
            }
            guard let toString = string(arguments, "to"), let toDate = parseDay(toString) else {
                throw McpToolError(message: "period=custom requires to (YYYY-MM-DD)")
            }
            customFrom = fromDate
            customTo = toDate
        }
        return range.dateRange(customFrom: customFrom, customTo: customTo)
    }

    static func parseDay(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.date(from: string)
    }

    /// Transcript pointer: the fast path derives the conventional location;
    /// subagent files live one level down and need a bounded scan.
    static func transcriptPath(for session: SessionSummary, claudeDir: URL) -> String? {
        let projectDir = claudeDir
            .appendingPathComponent("projects")
            .appendingPathComponent(session.projectId)
        let direct = projectDir.appendingPathComponent("\(session.id).jsonl")
        let fm = FileManager.default
        if fm.fileExists(atPath: direct.path) { return direct.path }
        guard session.isSubagent else { return nil }
        guard let enumerator = fm.enumerator(
            at: projectDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > 5000 { break }
            if url.lastPathComponent == "\(session.id).jsonl" { return url.path }
        }
        return nil
    }

    // MARK: - Shared DTOs

    struct SessionPointer: Encodable {
        let id: String
        let title: String
        let slug: String?
        let project: String
        let projectId: String
        let firstTs: String
        let lastTs: String
        let cost: Double
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheWriteTokens: Int
        let model: String?
        let messages: Int
        let toolCalls: Int
        let hasError: Bool
        let transcriptFile: String?
    }

    static func sessionPointer(_ session: SessionSummary, project: Project, claudeDir: URL) -> SessionPointer {
        SessionPointer(
            id: session.id,
            title: session.title,
            slug: session.slug,
            project: project.name,
            projectId: project.id,
            firstTs: session.firstTimestamp,
            lastTs: session.lastTimestamp,
            cost: round4(session.estimatedCost),
            inputTokens: session.totalInputTokens,
            outputTokens: session.totalOutputTokens,
            cacheReadTokens: session.totalCacheReadTokens,
            cacheWriteTokens: session.totalCacheCreationTokens,
            model: session.primaryModel,
            messages: session.messageCount,
            toolCalls: session.toolCallCount,
            hasError: session.hasError,
            transcriptFile: transcriptPath(for: session, claudeDir: claudeDir)
        )
    }
}

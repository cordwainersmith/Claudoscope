import Foundation
import MCP

extension McpToolHandlers {
    struct SessionListResponse: Encodable {
        let sessions: [SessionPointer]
        let truncated: Bool
    }

    // MARK: - list_sessions

    static func listSessions(_ arguments: [String: Value]?, _ context: McpToolContext) async throws -> CallTool.Result {
        let snapshot = await context.snapshot()
        let project = try await optionalProject(arguments, snapshot: snapshot, configService: context.configService)
        let includeSubagents = bool(arguments, "include_subagents") ?? false
        let maxCount = limit(arguments)

        var candidates = sessionsWithProjects(snapshot, projectId: project?.id)
        if !includeSubagents {
            candidates = candidates.filter { !$0.session.isSubagent }
        }
        candidates = filterByDateWindow(candidates, arguments: arguments)

        switch string(arguments, "sort") ?? "last_activity" {
        case "cost":
            candidates.sort { $0.session.estimatedCost > $1.session.estimatedCost }
        case "tokens":
            candidates.sort {
                ($0.session.totalInputTokens + $0.session.totalOutputTokens)
                    > ($1.session.totalInputTokens + $1.session.totalOutputTokens)
            }
        case "last_activity":
            candidates.sort { $0.session.lastTimestamp > $1.session.lastTimestamp }
        case let other:
            throw McpToolError(message: "Invalid sort \"\(other)\"; use last_activity, cost, or tokens")
        }

        return encodeJSON(SessionListResponse(
            sessions: candidates.prefix(maxCount).map {
                sessionPointer($0.session, project: $0.project, claudeDir: context.claudeDir)
            },
            truncated: candidates.count > maxCount
        ))
    }

    // MARK: - search_sessions

    static func searchSessions(_ arguments: [String: Value]?, _ context: McpToolContext) async throws -> CallTool.Result {
        guard let query = string(arguments, "query"), !query.isEmpty else {
            throw McpToolError(message: "search_sessions requires a query")
        }
        let snapshot = await context.snapshot()
        let project = try await optionalProject(arguments, snapshot: snapshot, configService: context.configService)
        let maxCount = limit(arguments)
        let terms = query.lowercased().split(separator: " ").map(String.init)

        var candidates = sessionsWithProjects(snapshot, projectId: project?.id)
            .filter { !$0.session.isSubagent }
        candidates = filterByDateWindow(candidates, arguments: arguments)

        // v1 matches metadata only (title/slug/project); the schema stays
        // stable when FTS5 transcript search lands behind this tool.
        let matches = candidates.filter { candidate in
            let haystack = [
                candidate.session.title,
                candidate.session.slug ?? "",
                candidate.project.name,
            ].joined(separator: " ").lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
        .sorted { $0.session.lastTimestamp > $1.session.lastTimestamp }

        return encodeJSON(SessionListResponse(
            sessions: matches.prefix(maxCount).map {
                sessionPointer($0.session, project: $0.project, claudeDir: context.claudeDir)
            },
            truncated: matches.count > maxCount
        ))
    }

    // MARK: - get_session

    struct SessionDetailResponse: Encodable {
        let session: SessionSummary
        let project: String
        let projectPath: String?
        let transcriptFile: String?
    }

    static func getSession(_ arguments: [String: Value]?, _ context: McpToolContext) async throws -> CallTool.Result {
        guard let id = string(arguments, "id"), !id.isEmpty else {
            throw McpToolError(message: "get_session requires an id")
        }
        let snapshot = await context.snapshot()
        guard let match = sessionsWithProjects(snapshot, projectId: nil)
            .first(where: { $0.session.id == id }) else {
            throw McpToolError(message: "No session with id \(id)")
        }
        let projectPath = await context.configService.decodeProjectPath(match.project.id)
        return encodeJSON(SessionDetailResponse(
            session: match.session,
            project: match.project.name,
            projectPath: projectPath,
            transcriptFile: transcriptPath(for: match.session, claudeDir: context.claudeDir)
        ))
    }

    // MARK: - Shared date filtering (session-level, keyed on lastTimestamp
    // like the dashboard's global filter, not dailyContributions)

    static func filterByDateWindow(
        _ candidates: [(session: SessionSummary, project: Project)],
        arguments: [String: Value]?
    ) -> [(session: SessionSummary, project: Project)] {
        let fromDate = string(arguments, "from").flatMap(parseDay)
        let toDate = string(arguments, "to").flatMap(parseDay).map {
            Calendar.current.date(byAdding: .day, value: 1, to: $0) ?? $0
        }
        guard fromDate != nil || toDate != nil else { return candidates }
        return candidates.filter { candidate in
            guard let last = ISO8601.parse(candidate.session.lastTimestamp) else { return false }
            if let fromDate, last < fromDate { return false }
            if let toDate, last >= toDate { return false }
            return true
        }
    }
}

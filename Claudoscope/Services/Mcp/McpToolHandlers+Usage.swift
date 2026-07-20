import Foundation
import MCP

extension McpToolHandlers {
    // MARK: - get_usage

    struct UsageResponse: Encodable {
        struct Period: Encodable {
            let from: String?
            let to: String?
        }
        struct Totals: Encodable {
            let sessions: Int
            let messages: Int
            let tokens: Int
            let cacheTokens: Int
            let cost: Double
        }
        struct Day: Encodable {
            let date: String
            let cost: Double
            let input: Int
            let output: Int
            let cacheRead: Int
            let cacheWrite: Int
            let sessions: Int
            let messages: Int
        }
        struct ModelRow: Encodable {
            let model: String
            let turns: Int
            let input: Int
            let output: Int
        }
        struct ProjectRow: Encodable {
            let project: String
            let projectId: String
            let cost: Double
            let tokens: Int
            let sessions: Int
            let messages: Int
        }
        struct Cache: Encodable {
            let hitRatio: Double
            let coverage: Double
            let readTokens: Int
            let writeTokens: Int
            let savings: Double
            let uncachedCost: Double
            let actualCost: Double
        }
        let period: Period
        let totals: Totals
        let perDay: [Day]
        let perModel: [ModelRow]
        let perProject: [ProjectRow]
        let cache: Cache
        let notes: [String]
    }

    static func getUsage(_ arguments: [String: Value]?, _ context: McpToolContext) async throws -> CallTool.Result {
        let snapshot = await context.snapshot()
        let project = try await optionalProject(arguments, snapshot: snapshot, configService: context.configService)
        let (from, to) = try periodRange(arguments)

        let sessions = sessionsWithProjects(snapshot, projectId: project?.id)
        let data = AnalyticsEngine.compute(
            sessions: sessions,
            pricingTable: snapshot.pricingTable,
            from: from,
            to: to
        )

        let iso = ISO8601DateFormatter()
        let response = UsageResponse(
            period: .init(from: from.map(iso.string), to: to.map(iso.string)),
            totals: .init(
                sessions: data.totalSessions,
                messages: data.totalMessages,
                tokens: data.totalTokens,
                cacheTokens: data.totalCacheTokens,
                cost: round4(data.totalCost)
            ),
            perDay: data.dailyUsage.map { day in
                .init(
                    date: day.date,
                    cost: round4(day.estimatedCost),
                    input: day.inputTokens,
                    output: day.outputTokens,
                    cacheRead: day.cacheReadTokens,
                    cacheWrite: day.cacheCreationTokens,
                    sessions: day.sessionCount,
                    messages: day.messageCount
                )
            },
            perModel: data.modelUsage.map { model in
                .init(
                    model: model.model,
                    turns: model.turnCount,
                    input: model.totalInputTokens,
                    output: model.totalOutputTokens
                )
            },
            perProject: data.projectCosts.map { projectCost in
                .init(
                    project: projectCost.projectName,
                    projectId: projectCost.projectId,
                    cost: round4(projectCost.totalCost),
                    tokens: projectCost.totalTokens,
                    sessions: projectCost.sessionCount,
                    messages: projectCost.messageCount
                )
            },
            cache: .init(
                hitRatio: round4(data.cacheAnalytics.hitRatio),
                coverage: round4(data.cacheAnalytics.cacheCoverage),
                readTokens: data.cacheAnalytics.totalCacheReadTokens,
                writeTokens: data.cacheAnalytics.totalCacheWriteTokens,
                savings: round4(data.cacheAnalytics.costSavings),
                uncachedCost: round4(data.cacheAnalytics.hypotheticalUncachedCost),
                actualCost: round4(data.cacheAnalytics.actualCost)
            ),
            notes: ["Cowork (desktop) spend is excluded; figures match the Claudoscope dashboard."]
        )
        return encodeJSON(response)
    }

    // MARK: - list_projects

    struct ProjectEntry: Encodable {
        let id: String
        let name: String
        let path: String?
        let sessionCount: Int
        let totalCost: Double
        let lastActivity: String?
    }

    static func listProjects(_ arguments: [String: Value]?, _ context: McpToolContext) async throws -> CallTool.Result {
        let snapshot = await context.snapshot()
        var entries: [ProjectEntry] = []
        for project in snapshot.projects {
            let sessions = snapshot.sessionsByProject[project.id] ?? []
            let realPath = await context.configService.decodeProjectPath(project.id)
            entries.append(ProjectEntry(
                id: project.id,
                name: project.name,
                path: realPath,
                sessionCount: sessions.filter { !$0.isSubagent }.count,
                totalCost: round4(sessions.reduce(0) { $0 + $1.estimatedCost }),
                lastActivity: sessions.map(\.lastTimestamp).max()
            ))
        }
        entries.sort { $0.lastActivity ?? "" > $1.lastActivity ?? "" }
        return encodeJSON(entries)
    }
}

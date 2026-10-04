import Foundation
import MCP

/// Fleet tools: the same agents, states and attention order as the Fleet
/// board. Read-only; no process is ever signalled. Environment variables and
/// registry key files are never exposed.
extension McpToolHandlers {

    static let agentStates = ["blocked", "waiting", "working", "idle", "failed", "done"]

    struct AgentPointer: Encodable {
        let sessionId: String
        let project: String
        let projectId: String
        let title: String
        let name: String?
        let state: String
        let reason: String?
        let since: String
        let waitedSeconds: Int
        let isLive: Bool
        let pid: Int?
        let status: String?
        let kind: String?
        let branch: String?
        let model: String?
        let cost: Double
        let inputTokens: Int
        let outputTokens: Int
        let contextTokens: Int?
        let contextWindowTokens: Int?
        let cacheExpiresAt: String?
        let isBypass: Bool
        let isBackgroundJob: Bool
        let transcriptFile: String?
    }

    struct AgentListResponse: Encodable {
        let agents: [AgentPointer]
        let attentionCount: Int
        let truncated: Bool
    }

    struct AgentDetailResponse: Encodable {
        let agent: AgentPointer
        let lastPrompt: String?
        let lastTool: String?
        let lastToolTarget: String?
        let lastToolAt: String?
        let cwd: String?
        let version: String?
        let blockedActions: Int?
        let changedFiles: Int?
        let failureReason: String?
    }

    static func agentPointer(_ agent: FleetAgent, now: Date, claudeDir: URL) -> AgentPointer {
        let summary = agent.summary
        let reason: String?
        switch agent.state {
        case .waitingOnUser(let text): reason = text
        case .blockedOnPermission: reason = "Permission prompt"
        default: reason = agent.failureReason
        }
        return AgentPointer(
            sessionId: summary.id,
            project: agent.projectName,
            projectId: summary.projectId,
            title: summary.title,
            name: agent.displayName,
            state: agent.state.filterKey,
            reason: reason,
            since: isoString(agent.since),
            waitedSeconds: agent.state.needsAttention ? max(0, Int(now.timeIntervalSince(agent.since))) : 0,
            isLive: agent.isLive,
            pid: agent.registry?.pid,
            status: agent.registry?.status,
            kind: agent.registry?.kind,
            branch: agent.branchLabel,
            model: summary.primaryModel.map { getModelFamily($0) },
            cost: round4(agent.totalCost),
            inputTokens: summary.totalInputTokens,
            outputTokens: summary.totalOutputTokens,
            contextTokens: summary.latestTurn?.contextTokens,
            contextWindowTokens: summary.latestTurn?.contextWindowTokens,
            cacheExpiresAt: agent.cacheExpiry().map(isoString),
            isBypass: agent.isBypass,
            isBackgroundJob: agent.isBackgroundJob,
            transcriptFile: summary.isCowork ? nil : transcriptPath(for: summary, claudeDir: claudeDir)
        )
    }

    /// Agents that need the user first (oldest wait first), then the rest in
    /// board order.
    static func listAgents(_ arguments: [String: Value]?, _ context: McpToolContext) async throws -> CallTool.Result {
        let snapshot = await context.snapshot()
        let attentionIds = Set(snapshot.attentionQueue.map(\.id))
        var agents = snapshot.attentionQueue + snapshot.fleetAgents.filter { !attentionIds.contains($0.id) }

        if let state = string(arguments, "state"), !state.isEmpty {
            guard agentStates.contains(state) else {
                throw McpToolError(message: "Invalid state \"\(state)\"; use one of \(agentStates.joined(separator: ", "))")
            }
            agents = agents.filter { $0.state.filterKey == state }
        }
        if let project = string(arguments, "project"), !project.isEmpty {
            agents = agents.filter {
                $0.summary.projectId == project || $0.projectName.caseInsensitiveCompare(project) == .orderedSame
            }
        }

        let maxCount = limit(arguments)
        let now = Date()
        return encodeJSON(AgentListResponse(
            agents: agents.prefix(maxCount).map { agentPointer($0, now: now, claudeDir: context.claudeDir) },
            attentionCount: snapshot.attentionQueue.count,
            truncated: agents.count > maxCount
        ))
    }

    static func getAgent(_ arguments: [String: Value]?, _ context: McpToolContext) async throws -> CallTool.Result {
        guard let sessionId = string(arguments, "session_id"), !sessionId.isEmpty else {
            throw McpToolError(message: "session_id is required")
        }
        let snapshot = await context.snapshot()
        guard let agent = snapshot.fleetAgents.first(where: { $0.id == sessionId }) else {
            throw McpToolError(message: "No agent with session id \(sessionId) on the Fleet board (live processes and sessions active in the last 24 hours)")
        }
        let turn = agent.summary.latestTurn
        return encodeJSON(AgentDetailResponse(
            agent: agentPointer(agent, now: Date(), claudeDir: context.claudeDir),
            lastPrompt: turn?.lastPrompt,
            lastTool: turn?.toolName,
            lastToolTarget: turn?.toolTarget,
            lastToolAt: turn?.toolTimestamp,
            cwd: agent.registry?.cwd,
            version: agent.registry?.version,
            blockedActions: agent.summary.blockedActionCount,
            changedFiles: agent.summary.changedFileCount,
            failureReason: agent.failureReason
        ))
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

import Foundation

// MARK: - Tool Cost Category

/// Coarse attribution of estimated spend, derived from reliable record signals
/// only: sidechain records => subagent, tool_use blocks named `mcp__*` => mcp,
/// everything else => other. Deliberately no "skill" bucket: skills are
/// indistinguishable from builtins by tool name.
enum ToolCostCategory: String, Hashable, Sendable, CaseIterable {
    case mcp
    case subagent
    case other
}

// MARK: - Parsed Session (full detail)

struct ParsedSession: Sendable {
    let id: String
    let projectId: String
    let slug: String?
    let records: [ParsedRecordRaw]
    let toolResultMap: [String: ToolResultEntry]
    let metadata: SessionMetadata
    let parentSessionId: String?
    let isSubagent: Bool

    init(id: String, projectId: String, slug: String?, records: [ParsedRecordRaw], toolResultMap: [String: ToolResultEntry], metadata: SessionMetadata, parentSessionId: String?, isSubagent: Bool = false) {
        self.id = id
        self.projectId = projectId
        self.slug = slug
        self.records = records
        self.toolResultMap = toolResultMap
        self.metadata = metadata
        self.parentSessionId = parentSessionId
        self.isSubagent = isSubagent
    }
}

struct ToolResultEntry: Sendable {
    let content: String
    let isError: Bool
    let timestamp: String?
}

// MARK: - Session Metadata

struct SessionMetadata: Sendable {
    let firstTimestamp: String
    let lastTimestamp: String
    let messageCount: Int
    let userMessageCount: Int
    let assistantMessageCount: Int
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalCacheReadTokens: Int
    let totalCacheCreationTokens: Int
    let models: [String]
    let compactionCount: Int
    let turnDurations: [TurnDuration]
    let effortDistribution: EffortDistribution
    let maxIdleGapSeconds: Double
    let idleGapAfterTimestamp: String?
    let compactionEvents: [CompactionEvent]
    let parallelToolGroups: [ParallelToolGroup]
    let errorDetails: [SessionErrorDetail]
}

// MARK: - Session Summary (lightweight for sidebar)

struct SessionSummary: Identifiable, Sendable {
    let id: String
    let projectId: String
    let slug: String?
    let title: String
    let firstTimestamp: String
    let lastTimestamp: String
    let messageCount: Int
    let primaryModel: String?
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalCacheReadTokens: Int
    let totalCacheCreationTokens: Int
    let totalCacheCreation5mTokens: Int
    let totalCacheCreation1hTokens: Int
    let compactionCount: Int
    let estimatedCost: Double
    let hasError: Bool
    let modelBreakdown: [ModelTokenBreakdown]
    let toolCallCount: Int
    let observability: SessionObservability
    let isSubagent: Bool
    /// Estimated cost split by coarse category (mcp / subagent / other).
    /// Defaults to empty so non-parser constructors keep compiling.
    let costByCategory: [ToolCostCategory: Double]
    /// Number of billed assistant turns that ran in fast mode (usage.speed
    /// present and != "standard"). Defaults to 0 for non-parser constructors.
    let fastModeTurnCount: Int

    init(
        id: String,
        projectId: String,
        slug: String?,
        title: String,
        firstTimestamp: String,
        lastTimestamp: String,
        messageCount: Int,
        primaryModel: String?,
        totalInputTokens: Int,
        totalOutputTokens: Int,
        totalCacheReadTokens: Int,
        totalCacheCreationTokens: Int,
        totalCacheCreation5mTokens: Int,
        totalCacheCreation1hTokens: Int,
        compactionCount: Int,
        estimatedCost: Double,
        hasError: Bool,
        modelBreakdown: [ModelTokenBreakdown],
        toolCallCount: Int,
        observability: SessionObservability,
        isSubagent: Bool,
        costByCategory: [ToolCostCategory: Double] = [:],
        fastModeTurnCount: Int = 0
    ) {
        self.id = id
        self.projectId = projectId
        self.slug = slug
        self.title = title
        self.firstTimestamp = firstTimestamp
        self.lastTimestamp = lastTimestamp
        self.messageCount = messageCount
        self.primaryModel = primaryModel
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.totalCacheReadTokens = totalCacheReadTokens
        self.totalCacheCreationTokens = totalCacheCreationTokens
        self.totalCacheCreation5mTokens = totalCacheCreation5mTokens
        self.totalCacheCreation1hTokens = totalCacheCreation1hTokens
        self.compactionCount = compactionCount
        self.estimatedCost = estimatedCost
        self.hasError = hasError
        self.modelBreakdown = modelBreakdown
        self.toolCallCount = toolCallCount
        self.observability = observability
        self.isSubagent = isSubagent
        self.costByCategory = costByCategory
        self.fastModeTurnCount = fastModeTurnCount
    }
}

struct ModelTokenBreakdown: Sendable {
    let model: String           // model family: "opus", "sonnet", "haiku"
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let estimatedCost: Double
    let turnCount: Int
}

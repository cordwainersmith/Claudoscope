import Foundation

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
    /// Per-day breakdown of billed cost/tokens, keyed by the LOCAL calendar day
    /// each billable message landed on. Summing these reproduces the lump fields
    /// above; date-windowed analytics sum only the in-range days so a `/resume`d
    /// session's earlier-day spend is not counted under "today".
    let dailyContributions: [DailyContribution]

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
        dailyContributions: [DailyContribution]
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
        self.dailyContributions = dailyContributions
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

/// Per-family cost/tokens billed on a single calendar day. Lives inside a
/// `DailyContribution`, so the family rollups stay date-accurate under a window.
struct ModelDayCost: Sendable {
    let model: String           // model family: "opus", "sonnet", "haiku"
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let estimatedCost: Double
    let turnCount: Int
}

/// One calendar day's worth of billed activity for a session. `date` is the
/// LOCAL day (YYYY-MM-DD) the messages landed on, fixed at parse time.
struct DailyContribution: Sendable {
    let date: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    let cacheCreation5mTokens: Int
    let cacheCreation1hTokens: Int
    let estimatedCost: Double
    let modelBreakdown: [ModelDayCost]
}

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

struct SessionSummary: Identifiable, Sendable, Codable, Equatable {
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
    /// True for summaries synthesized from Cowork (Claude desktop) sessions.
    /// They feed the menu bar popover only and must never enter the CLI
    /// project index or Analytics (Cowork cost is added there separately).
    let isCowork: Bool
    /// Per-day breakdown of billed cost/tokens, keyed by the LOCAL calendar day
    /// each billable message landed on. Summing these reproduces the lump fields
    /// above; date-windowed analytics sum only the in-range days so a `/resume`d
    /// session's earlier-day spend is not counted under "today".
    let dailyContributions: [DailyContribution]
    /// Subagent linkage (subagent files only): this file's bare agent id and the
    /// bare ids of subagents it spawned (via toolUseResult.agentId).
    let agentId: String?
    let spawnedAgentIds: [String]
    /// Provenance stamped by Claude Code: the worktree a `--worktree` or `/fork`
    /// session ran in, and the PR or GitLab MR it opened. Nil for an ordinary
    /// session in the project checkout. Defaulted so the memberwise init stays
    /// source-compatible with every existing call site.
    var worktreeName: String? = nil
    var worktreeBranch: String? = nil
    var prNumber: Int? = nil
    var prUrl: String? = nil
    /// Aggregated hook runtime extracted from hook_success attachment records
    /// and stop_hook_summary system records. Nil when the session ran no hooks
    /// or the cached blob predates parserVersion 7.
    var hookRunStats: HookRunStats? = nil
    /// Subagent files only: the agent type Claude Code attributed the whole
    /// file to ("Explore", "Plan", "general-purpose"). One value per subagent
    /// file, so a scalar rather than a breakdown. Nil for main sessions.
    var attributionAgent: String? = nil
    /// Claude Code's session classification; "bg" for a background session.
    /// Nil for an ordinary interactive session.
    var sessionKind: String? = nil
    /// Un-windowed rollups of the per-day attribution arrays, for the config
    /// rails and session detail. Date-windowed analytics must fold
    /// `dailyContributions` instead, not these.
    ///
    /// Optional, not a defaulted array: Swift's synthesized Codable ignores
    /// property defaults and throws on a missing key, so a non-optional here
    /// would turn every pre-parserVersion-8 blob into a cache miss. Nil means
    /// "no attribution data in this blob"; [] means "parsed, nothing tagged".
    var skillBreakdown: [SkillAttribution]? = nil
    var mcpBreakdown: [McpAttribution]? = nil

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
        dailyContributions: [DailyContribution],
        isCowork: Bool = false,
        agentId: String? = nil,
        spawnedAgentIds: [String] = [],
        worktreeName: String? = nil,
        worktreeBranch: String? = nil,
        prNumber: Int? = nil,
        prUrl: String? = nil,
        hookRunStats: HookRunStats? = nil,
        attributionAgent: String? = nil,
        sessionKind: String? = nil,
        skillBreakdown: [SkillAttribution]? = nil,
        mcpBreakdown: [McpAttribution]? = nil
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
        self.isCowork = isCowork
        self.agentId = agentId
        self.spawnedAgentIds = spawnedAgentIds
        self.worktreeName = worktreeName
        self.worktreeBranch = worktreeBranch
        self.prNumber = prNumber
        self.prUrl = prUrl
        self.hookRunStats = hookRunStats
        self.attributionAgent = attributionAgent
        self.sessionKind = sessionKind
        self.skillBreakdown = skillBreakdown
        self.mcpBreakdown = mcpBreakdown
    }
}

struct ModelTokenBreakdown: Sendable, Codable, Equatable {
    let model: String           // model family: "opus", "sonnet", "haiku"
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let estimatedCost: Double
    let turnCount: Int
}

/// Per-family cost/tokens billed on a single calendar day. Lives inside a
/// `DailyContribution`, so the family rollups stay date-accurate under a window.
struct ModelDayCost: Sendable, Codable, Equatable {
    let model: String           // model family: "opus", "sonnet", "haiku"
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let estimatedCost: Double
    let turnCount: Int
}

/// Cost billed on records Claude Code tagged with `attributionSkill`.
///
/// A PARTIAL partition: only about a tenth of billed records carry any
/// attribution tag, so `sum(estimatedCost)` is always <= the enclosing total and
/// the remainder is unattributed. Never render these rows without showing that
/// remainder, and never normalize them to 100%.
struct SkillAttribution: Sendable, Codable, Equatable, Identifiable {
    var id: String { skill }
    /// The raw tag. Comes in two forms — bare ("dataviz") and plugin-qualified
    /// ("frontend-design:frontend-design") — and the same skill can appear in
    /// both, so any join against installed skills needs a normalizer.
    let skill: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let estimatedCost: Double
    let turnCount: Int
}

/// Cost billed on records tagged with `attributionMcpServer` + `attributionMcpTool`.
/// Claude Code tags the turns downstream of an MCP tool result, so this measures
/// spend while that tool's result was driving the turn, not just the call itself.
///
/// Server and tool stay separate fields: the MCPs rail joins on server, the
/// analytics table displays both.
///
/// Independent of `SkillAttribution`, not a sibling slice of it: a single record
/// can carry both tags, so the two sums can together exceed the day's cost.
struct McpAttribution: Sendable, Codable, Equatable, Identifiable {
    var id: String { server + "/" + tool }
    let server: String
    let tool: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let estimatedCost: Double
    let turnCount: Int
}

/// One calendar day's worth of billed activity for a session. `date` is the
/// LOCAL day (YYYY-MM-DD) the messages landed on, fixed at parse time.
struct DailyContribution: Sendable, Codable, Equatable {
    let date: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    let cacheCreation5mTokens: Int
    let cacheCreation1hTokens: Int
    let estimatedCost: Double
    let modelBreakdown: [ModelDayCost]
    /// Partial attribution partitions for this day. Optional rather than a
    /// defaulted array because synthesized Codable ignores property defaults:
    /// a non-optional would break decoding of every pre-v8 blob.
    var skillBreakdown: [SkillAttribution]? = nil
    var mcpBreakdown: [McpAttribution]? = nil
}

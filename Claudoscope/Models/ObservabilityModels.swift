import Foundation

// MARK: - Turn Duration

struct TurnDuration: Identifiable, Sendable {
    var id: Int { turnIndex }
    let turnIndex: Int
    let userTimestamp: String?
    let assistantTimestamp: String?
    let durationMs: Double
    let isPostCompaction: Bool
    let inputTokens: Int
    let model: String?
}

// MARK: - Effort Level

enum EffortLevel: String, CaseIterable, Sendable, Codable {
    case low
    case medium
    case high
    case xhigh
    case max

    var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "X-High"
        case .max: return "Max"
        }
    }
}

// MARK: - Effort Distribution

/// Turn counts per effort level. Since Claude Code records the level on every
/// assistant record, these are recorded values; `estimatedTurns` counts the
/// turns from older transcripts whose level was inferred by
/// `ObservabilityAnalyzer.classifyEffort` instead.
struct EffortDistribution: Sendable, Codable, Equatable {
    let low: Int
    let medium: Int
    let high: Int
    let xhigh: Int
    let max: Int
    let estimatedTurns: Int

    var total: Int { low + medium + high + xhigh + max }

    init(low: Int, medium: Int, high: Int, xhigh: Int, max: Int, estimatedTurns: Int = 0) {
        self.low = low
        self.medium = medium
        self.high = high
        self.xhigh = xhigh
        self.max = max
        self.estimatedTurns = estimatedTurns
    }

    init(counts: [EffortLevel: Int], estimatedTurns: Int) {
        self.init(
            low: counts[.low, default: 0],
            medium: counts[.medium, default: 0],
            high: counts[.high, default: 0],
            xhigh: counts[.xhigh, default: 0],
            max: counts[.max, default: 0],
            estimatedTurns: estimatedTurns
        )
    }

    func count(_ level: EffortLevel) -> Int {
        switch level {
        case .low: return low
        case .medium: return medium
        case .high: return high
        case .xhigh: return xhigh
        case .max: return max
        }
    }

    static let zero = EffortDistribution(low: 0, medium: 0, high: 0, xhigh: 0, max: 0)
}

// MARK: - Effort Cost Breakdown

struct EffortCostBreakdown: Identifiable, Sendable {
    var id: String { level.rawValue }
    let level: EffortLevel
    let turnCount: Int
    let totalCost: Double
    let avgCostPerTurn: Double
    /// Mean recorded thinking time per turn; nil when no turn at this level
    /// recorded one.
    var avgThinkingMs: Double? = nil
    /// Share of this level's turns whose level was inferred, not recorded.
    var estimatedShare: Double = 0
}

// MARK: - Error Classification

enum ErrorClassification: String, CaseIterable, Sendable, Codable {
    case rateLimit
    case authFailure
    case proxyError
    case maxTokensTruncation
    case missingToolResult
    case abruptEnding
    case toolError
    case unknown

    var label: String {
        switch self {
        case .rateLimit: return "Rate Limit"
        case .authFailure: return "Auth Failure"
        case .proxyError: return "Proxy Error"
        case .maxTokensTruncation: return "Max Tokens Truncation"
        case .missingToolResult: return "Missing Tool Result"
        case .abruptEnding: return "Abrupt Ending"
        case .toolError: return "Tool Error"
        case .unknown: return "Unknown"
        }
    }
}

// MARK: - Session Error Detail

struct SessionErrorDetail: Sendable {
    let classification: ErrorClassification
    let turnIndex: Int
    let timestamp: String?
    let message: String
}

// MARK: - Compaction Event

struct CompactionEvent: Identifiable, Sendable {
    var id: Int { index }
    let index: Int
    let timestamp: String?
    let preTokens: Int?
    let turnsSinceLastCompaction: Int
}

// MARK: - Parallel Tool Group

struct ParallelToolGroup: Identifiable, Sendable {
    var id: String { "\(turnIndex)-\(toolCount)" }
    let turnIndex: Int
    let timestamp: String?
    let toolNames: [String]
    let toolCount: Int
}

// MARK: - Subagent Node

struct SubagentNode: Identifiable, Sendable {
    let id: String
    let sessionTitle: String
    let model: String?
    /// Effort the subagent actually ran at (CC 2.1.243 made it per-subagent).
    /// Nil on a transcript that predates the per-record `effort` field.
    let effort: EffortLevel?
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let estimatedCost: Double
    let toolCallCount: Int
    let messageCount: Int
    let children: [SubagentNode]
}

// MARK: - Session Observability

struct SessionObservability: Sendable, Codable, Equatable {
    let medianTurnDurationMs: Double?
    let maxTurnDurationMs: Double?
    let dominantEffortLevel: EffortLevel?
    let effortDistribution: EffortDistribution
    let errorClassifications: [ErrorClassification]
    let hasIdleZombieGap: Bool
    let estimatedIdleWasteCost: Double
    let compactionTimestamps: [String]
    let parallelToolCallCount: Int
    let maxParallelDegree: Int
    let isWorktreeSession: Bool

    static let empty = SessionObservability(
        medianTurnDurationMs: nil,
        maxTurnDurationMs: nil,
        dominantEffortLevel: nil,
        effortDistribution: .zero,
        errorClassifications: [],
        hasIdleZombieGap: false,
        estimatedIdleWasteCost: 0,
        compactionTimestamps: [],
        parallelToolCallCount: 0,
        maxParallelDegree: 0,
        isWorktreeSession: false
    )
}

// MARK: - Hook Runtime Stats

/// Per-hook-command aggregate for one session, folded at parse time from
/// hook_success attachment records and stop_hook_summary system records.
struct HookCommandRunStats: Sendable, Codable, Equatable, Identifiable {
    var id: String { hookName + "|" + command }
    let hookName: String        // "PreToolUse:Bash", "Stop", ...
    let command: String         // script path as recorded in the transcript
    let fireCount: Int
    let errorCount: Int
    let totalDurationMs: Int
    let maxDurationMs: Int
}

/// Aggregated hook runtime for one session. Bounded by (hook events x
/// configured commands); never stores per-event data.
struct HookRunStats: Sendable, Codable, Equatable {
    let perCommand: [HookCommandRunStats]
    let stopHookRuns: Int
    let preventedContinuationCount: Int

    var totalFires: Int { perCommand.reduce(0) { $0 + $1.fireCount } }
    var totalErrors: Int { perCommand.reduce(0) { $0 + $1.errorCount } }

    static let empty = HookRunStats(perCommand: [], stopHookRuns: 0, preventedContinuationCount: 0)
}

// MARK: - Session Badge Data

struct SessionBadgeData: Sendable {
    let hasErrors: Bool
    let isZombie: Bool
    let errorTypes: [ErrorClassification]

    static let none = SessionBadgeData(hasErrors: false, isZombie: false, errorTypes: [])
}

// MARK: - Blocked / Denied Actions

enum BlockedActionKind: String, Sendable {
    case destructiveGit
    case iacDestroy
    case permissionSetting
    case userRejected
    case safetyCheck
    case modeDenied
    case other

    var label: String {
        switch self {
        case .destructiveGit: return "Destructive git"
        case .iacDestroy: return "Infra destroy"
        case .permissionSetting: return "Permission denied"
        case .userRejected: return "User rejected"
        case .safetyCheck: return "Safety check"
        case .modeDenied: return "Mode denied"
        case .other: return "Blocked"
        }
    }
}

struct BlockedAction: Identifiable, Sendable {
    let id: String          // originating tool_use id
    let toolName: String
    let command: String?    // primary argument (command for Bash)
    let kind: BlockedActionKind
    let reason: String      // the denial text
    let turnIndex: Int
    let timestamp: String?
}

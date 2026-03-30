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

enum EffortLevel: String, CaseIterable, Sendable {
    case low
    case medium
    case high
    case ultrathink

    var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .ultrathink: return "Ultra-think"
        }
    }
}

// MARK: - Effort Distribution

struct EffortDistribution: Sendable {
    let low: Int
    let medium: Int
    let high: Int
    let ultrathink: Int

    var total: Int { low + medium + high + ultrathink }

    static let zero = EffortDistribution(low: 0, medium: 0, high: 0, ultrathink: 0)
}

// MARK: - Effort Cost Breakdown

struct EffortCostBreakdown: Identifiable, Sendable {
    var id: String { level.rawValue }
    let level: EffortLevel
    let turnCount: Int
    let totalCost: Double
    let avgCostPerTurn: Double
}

// MARK: - Error Classification

enum ErrorClassification: String, CaseIterable, Sendable {
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
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let estimatedCost: Double
    let toolCallCount: Int
    let messageCount: Int
    let children: [SubagentNode]
}

// MARK: - Session Observability

struct SessionObservability: Sendable {
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
        maxParallelDegree: 0
    )
}

// MARK: - Session Badge Data

struct SessionBadgeData: Sendable {
    let hasErrors: Bool
    let isZombie: Bool
    let errorTypes: [ErrorClassification]

    static let none = SessionBadgeData(hasErrors: false, isZombie: false, errorTypes: [])
}

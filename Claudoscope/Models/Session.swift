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
    let estimatedCost: Double
    let hasError: Bool
}

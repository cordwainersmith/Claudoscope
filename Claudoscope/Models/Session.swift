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
    let compactionCount: Int
    let estimatedCost: Double
    let hasError: Bool
}

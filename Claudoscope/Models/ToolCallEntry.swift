import Foundation

struct ToolCallEntry: Identifiable, Sendable {
    let id: String              // tool_use block id
    let toolName: String
    let category: ToolCategory
    let input: [String: AnyCodableValue]
    let primaryArg: String?     // file_path, command, pattern
    let resultContent: String?
    let isError: Bool
    let turnIndex: Int
    let sessionId: String
    let timestamp: String?
}

struct ToolAnalytics: Sendable {
    let totalCalls: Int
    let errorCount: Int
    let errorRate: Double
    let uniqueFilesTouched: Int
    let callsByTool: [(tool: String, count: Int)]
    let callsByCategory: [(category: ToolCategory, count: Int)]

    static let empty = ToolAnalytics(
        totalCalls: 0, errorCount: 0, errorRate: 0,
        uniqueFilesTouched: 0, callsByTool: [], callsByCategory: []
    )
}

/// Extract tool calls from a parsed session
func extractToolCalls(from session: ParsedSession) -> [ToolCallEntry] {
    var entries: [ToolCallEntry] = []
    var turnIndex = 0

    for record in session.records {
        guard record.type == .assistant else { continue }
        turnIndex += 1

        guard case .blocks(let blocks) = record.message?.content else { continue }

        for block in blocks where block.type == "tool_use" {
            guard let toolId = block.id, let name = block.name else { continue }
            let input = block.input ?? [:]
            let result = session.toolResultMap[toolId]

            entries.append(ToolCallEntry(
                id: toolId,
                toolName: name,
                category: toolCategory(for: name),
                input: input,
                primaryArg: primaryArgument(from: input, toolName: name),
                resultContent: result?.content,
                isError: result?.isError ?? false,
                turnIndex: turnIndex,
                sessionId: session.id,
                timestamp: result?.timestamp ?? record.timestamp
            ))
        }
    }

    return entries
}

/// Compute analytics from tool call entries
func computeToolAnalytics(_ entries: [ToolCallEntry]) -> ToolAnalytics {
    guard !entries.isEmpty else { return .empty }

    let errorCount = entries.filter(\.isError).count
    let errorRate = Double(errorCount) / Double(entries.count)

    // Unique files touched (from Read/Write/Edit file_path args)
    var files = Set<String>()
    for entry in entries {
        if let path = entry.input["file_path"]?.stringValue {
            files.insert(path)
        }
    }

    // Count by tool name
    var toolCounts: [String: Int] = [:]
    for entry in entries {
        toolCounts[entry.toolName, default: 0] += 1
    }
    let callsByTool = toolCounts.sorted { $0.value > $1.value }.map { (tool: $0.key, count: $0.value) }

    // Count by category
    var catCounts: [ToolCategory: Int] = [:]
    for entry in entries {
        catCounts[entry.category, default: 0] += 1
    }
    let callsByCategory = catCounts.sorted { $0.value > $1.value }.map { (category: $0.key, count: $0.value) }

    return ToolAnalytics(
        totalCalls: entries.count,
        errorCount: errorCount,
        errorRate: errorRate,
        uniqueFilesTouched: files.count,
        callsByTool: callsByTool,
        callsByCategory: callsByCategory
    )
}

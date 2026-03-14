import Foundation

/// Display-ready content block for rendering in chat view
enum ContentBlock: Identifiable, Sendable {
    case text(id: String, text: String)
    case thinking(id: String, thinking: String)
    case toolUse(id: String, toolName: String, input: [String: AnyCodableValue], resultContent: String?, isError: Bool)
    case toolResult(id: String, toolUseId: String, content: String, isError: Bool)

    var id: String {
        switch self {
        case .text(let id, _): return id
        case .thinking(let id, _): return id
        case .toolUse(let id, _, _, _, _): return id
        case .toolResult(let id, _, _, _): return id
        }
    }
}

/// Display-ready message for rendering
struct DisplayMessage: Identifiable, Sendable {
    let id: String
    let type: RecordType
    let timestamp: String?
    let model: String?
    let inputTokens: Int
    let outputTokens: Int
    let contentBlocks: [ContentBlock]
    let isCompactionBoundary: Bool
    let isContinuation: Bool
}

struct TokenUsage: Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int

    var totalTokens: Int { inputTokens + outputTokens }
}

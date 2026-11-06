import Foundation

/// What each API request of a session was made of, rebuilt from the request
/// log Claude Code 2.1.300+ writes into the transcript (`api-request`,
/// `api-request-shape`, `api-request-blob`). Sizes are measured in bytes and
/// turned into tokens by splitting the request's real input token count
/// (from the matching assistant record's usage) in proportion to bytes.
enum AnatomyCategory: String, CaseIterable, Sendable {
    case system
    case builtinTools
    case mcpTools
    case reminders
    case conversation

    var label: String {
        switch self {
        case .system: return "System prompt"
        case .builtinTools: return "Built-in tools"
        case .mcpTools: return "MCP tools"
        case .reminders: return "Instructions & reminders"
        case .conversation: return "Conversation"
        }
    }
}

struct AnatomyPoint: Sendable, Identifiable, Equatable {
    let id: String
    let timestamp: String
    let querySource: String
    let model: String?
    let effort: String?
    let bytes: [AnatomyCategory: Int]
    /// Tools sent with `defer_loading` (found through tool search); they are
    /// not loaded into the context window, so they are not in `bytes`.
    let deferredToolCount: Int
    let tokens: [AnatomyCategory: Int]
    /// True when the total is the request's real input size (from the billed
    /// assistant record that points at it). The split between categories is
    /// always by size; conversation is what remains after the measured parts.
    /// False means the whole point is a bytes/4 estimate.
    let isMeasured: Bool

    var totalTokens: Int { tokens.values.reduce(0, +) }
}

struct AnatomyServerRow: Sendable, Identifiable, Equatable {
    var id: String { server }
    let server: String
    let tokens: Int
    let toolCount: Int
}

struct AnatomyToolRow: Sendable, Identifiable, Equatable {
    var id: String { name }
    let name: String
    let tokens: Int
}

struct AnatomyDetail: Sendable, Equatable {
    let point: AnatomyPoint
    let mcpByServer: [AnatomyServerRow]
    let topTools: [AnatomyToolRow]
}

struct RequestAnatomy: Sendable, Equatable {
    let sessionKey: String
    /// The session's own requests in time order (main conversation for a top
    /// level transcript, everything for a subagent transcript).
    let points: [AnatomyPoint]
    let latest: AnatomyDetail?
    let peak: AnatomyDetail?
}

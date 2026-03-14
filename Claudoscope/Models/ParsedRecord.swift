import Foundation

// MARK: - Record Types

enum RecordType: String, Codable, Sendable {
    case user
    case assistant
    case toolResult = "tool_result"
    case system
    case summary
    case result
    case fileHistorySnapshot = "file-history-snapshot"
    case progress
}

// MARK: - Raw JSONL Record (lenient Decodable)

/// Represents a single line from a Claude Code JSONL session file.
/// All fields optional with defaults for forward-compatibility.
struct ParsedRecordRaw: Decodable, Sendable {
    let type: RecordType?
    let uuid: String?
    let parentUuid: String?
    let timestamp: String?
    let sessionId: String?
    let cwd: String?
    let slug: String?

    // user/assistant records
    let message: MessageRaw?

    // system records
    let subtype: String?
    let content: String?
    let compactMetadata: CompactMetadataRaw?
    let logicalParentUuid: String?

    // tool_result records
    let toolUseResult: ToolUseResultRaw?

    // flags
    let isCompactSummary: Bool?
    let isVisibleInTranscriptOnly: Bool?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(RecordType.self, forKey: .type)
        uuid = try container.decodeIfPresent(String.self, forKey: .uuid)
        parentUuid = try container.decodeIfPresent(String.self, forKey: .parentUuid)
        timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        slug = try container.decodeIfPresent(String.self, forKey: .slug)
        message = try container.decodeIfPresent(MessageRaw.self, forKey: .message)
        subtype = try container.decodeIfPresent(String.self, forKey: .subtype)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        compactMetadata = try container.decodeIfPresent(CompactMetadataRaw.self, forKey: .compactMetadata)
        logicalParentUuid = try container.decodeIfPresent(String.self, forKey: .logicalParentUuid)
        toolUseResult = try container.decodeIfPresent(ToolUseResultRaw.self, forKey: .toolUseResult)
        isCompactSummary = try container.decodeIfPresent(Bool.self, forKey: .isCompactSummary)
        isVisibleInTranscriptOnly = try container.decodeIfPresent(Bool.self, forKey: .isVisibleInTranscriptOnly)
    }

    enum CodingKeys: String, CodingKey {
        case type, uuid, parentUuid, timestamp, sessionId, cwd, slug
        case message, subtype, content, compactMetadata, logicalParentUuid
        case toolUseResult, isCompactSummary, isVisibleInTranscriptOnly
    }
}

// MARK: - Message

struct MessageRaw: Decodable, Sendable {
    let role: String?
    let content: MessageContentRaw?
    let id: String?
    let model: String?
    let stopReason: String?
    let usage: TokenUsageRaw?

    enum CodingKeys: String, CodingKey {
        case role, content, id, model
        case stopReason = "stop_reason"
        case usage
    }
}

/// Message content can be either a plain string or an array of content blocks
enum MessageContentRaw: Decodable, Sendable {
    case string(String)
    case blocks([ContentBlockRaw])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .string(str)
        } else if let blocks = try? container.decode([ContentBlockRaw].self) {
            self = .blocks(blocks)
        } else {
            self = .string("")
        }
    }

    var textContent: String {
        switch self {
        case .string(let s):
            return s
        case .blocks(let blocks):
            return blocks.compactMap { block in
                if block.type == "text" { return block.text }
                return nil
            }.joined(separator: "\n")
        }
    }
}

// MARK: - Content Block (raw from JSON)

struct ContentBlockRaw: Decodable, Sendable {
    let type: String?
    let text: String?
    let thinking: String?
    let id: String?
    let name: String?
    let input: [String: AnyCodableValue]?

    // tool_result block fields (embedded in user messages)
    let toolUseId: String?
    let content: ToolResultContentRaw?
    let isError: Bool?

    enum CodingKeys: String, CodingKey {
        case type, text, thinking, id, name, input
        case toolUseId = "tool_use_id"
        case content
        case isError = "is_error"
    }
}

/// Tool result content can be a string or array of text blocks
enum ToolResultContentRaw: Decodable, Sendable {
    case string(String)
    case blocks([ToolResultTextBlock])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .string(str)
        } else if let blocks = try? container.decode([ToolResultTextBlock].self) {
            self = .blocks(blocks)
        } else {
            self = .string("")
        }
    }

    var textContent: String {
        switch self {
        case .string(let s): return s
        case .blocks(let blocks):
            return blocks.filter { $0.type == "text" }.map { $0.text }.joined(separator: "\n")
        }
    }
}

struct ToolResultTextBlock: Decodable, Sendable {
    let type: String
    let text: String
}

// MARK: - Token Usage

struct TokenUsageRaw: Decodable, Sendable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
    }
}

// MARK: - Tool Use Result

struct ToolUseResultRaw: Decodable, Sendable {
    let toolUseId: String?
    let content: String?
    let isError: Bool?

    enum CodingKeys: String, CodingKey {
        case toolUseId = "tool_use_id"
        case content
        case isError = "is_error"
    }
}

// MARK: - Compact Metadata

struct CompactMetadataRaw: Decodable, Sendable {
    let trigger: String?
    let preTokens: Int?
}

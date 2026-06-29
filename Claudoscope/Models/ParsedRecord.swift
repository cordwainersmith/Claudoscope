import Foundation

// MARK: - Decode Mode

enum DecodeMode: Sendable { case lite, full }

extension CodingUserInfoKey {
    static let decodeMode = CodingUserInfoKey(rawValue: "decodeMode")!
}

extension Decoder {
    var decodeMode: DecodeMode {
        (userInfo[.decodeMode] as? DecodeMode) ?? .full
    }
}

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

    // file-history-snapshot records (CC checkpointing / /rewind)
    let snapshot: FileHistorySnapshotRaw?   // full-only: the tracked-file backup map
    let isSnapshotUpdate: Bool?             // both modes
    let messageId: String?                  // top-level messageId (== the assistant turn uuid)

    // flags
    let isCompactSummary: Bool?
    let isVisibleInTranscriptOnly: Bool?
    let isSidechain: Bool?

    // /rename writes type:"custom-title" / type:"agent-name" records
    // carrying these fields. Kept here so the rest of the record decodes
    // even when `type` is one of those (and the lenient `try?` on type
    // means unknown enum cases yield nil instead of dropping the record).
    let customTitle: String?
    let agentName: String?

    // Session-level display title. Forward-compatible: no current Claude Code
    // record carries a root `title`, so this decodes to nil today. If a future
    // CLI version stamps a session title, deriveTitle() prefers it over slug.
    let title: String?

    // Captures the raw `type` string when it doesn't match a known RecordType,
    // so a future telemetry layer can surface unrecognized record types instead
    // of silently dropping them.
    let unknownTypeRaw: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mode = decoder.decodeMode
        let decodedType = try? container.decode(RecordType.self, forKey: .type)
        type = decodedType
        if mode == .full, decodedType == nil {
            unknownTypeRaw = try? container.decode(String.self, forKey: .type)
        } else {
            unknownTypeRaw = nil
        }
        uuid = try container.decodeIfPresent(String.self, forKey: .uuid)
        timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        slug = try container.decodeIfPresent(String.self, forKey: .slug)
        message = try container.decodeIfPresent(MessageRaw.self, forKey: .message)
        subtype = try container.decodeIfPresent(String.self, forKey: .subtype)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        compactMetadata = try container.decodeIfPresent(CompactMetadataRaw.self, forKey: .compactMetadata)
        toolUseResult = try container.decodeIfPresent(ToolUseResultRaw.self, forKey: .toolUseResult)
        isSnapshotUpdate = try container.decodeIfPresent(Bool.self, forKey: .isSnapshotUpdate)
        messageId = try container.decodeIfPresent(String.self, forKey: .messageId)
        isCompactSummary = try container.decodeIfPresent(Bool.self, forKey: .isCompactSummary)
        isVisibleInTranscriptOnly = try container.decodeIfPresent(Bool.self, forKey: .isVisibleInTranscriptOnly)
        // Always-decoded; needed for sidechain (subagent) detection in both modes.
        isSidechain = try container.decodeIfPresent(Bool.self, forKey: .isSidechain)
        customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
        agentName = try container.decodeIfPresent(String.self, forKey: .agentName)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        if mode == .full {
            parentUuid = try container.decodeIfPresent(String.self, forKey: .parentUuid)
            cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
            logicalParentUuid = try container.decodeIfPresent(String.self, forKey: .logicalParentUuid)
            snapshot = try container.decodeIfPresent(FileHistorySnapshotRaw.self, forKey: .snapshot)
        } else {
            parentUuid = nil
            cwd = nil
            logicalParentUuid = nil
            snapshot = nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, uuid, parentUuid, timestamp, sessionId, cwd, slug
        case message, subtype, content, compactMetadata, logicalParentUuid
        case toolUseResult, isCompactSummary, isVisibleInTranscriptOnly
        case customTitle, agentName, isSidechain, title
        case snapshot, isSnapshotUpdate, messageId
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        content = try container.decodeIfPresent(MessageContentRaw.self, forKey: .content)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        stopReason = try container.decodeIfPresent(String.self, forKey: .stopReason)
        usage = try container.decodeIfPresent(TokenUsageRaw.self, forKey: .usage)
        // Always decode id; needed in lite mode for cost dedup, since Claude Code
        // re-persists the same API response (same msg_id) across tool-use turns.
        id = try container.decodeIfPresent(String.self, forKey: .id)
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        thinking = try container.decodeIfPresent(String.self, forKey: .thinking)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        if decoder.decodeMode == .full {
            id = try container.decodeIfPresent(String.self, forKey: .id)
            input = try container.decodeIfPresent([String: AnyCodableValue].self, forKey: .input)
            toolUseId = try container.decodeIfPresent(String.self, forKey: .toolUseId)
            content = try container.decodeIfPresent(ToolResultContentRaw.self, forKey: .content)
            isError = try container.decodeIfPresent(Bool.self, forKey: .isError)
        } else {
            id = nil
            input = nil
            toolUseId = nil
            content = nil
            isError = nil
        }
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

struct CacheCreationBreakdown: Decodable, Sendable {
    let ephemeral5mInputTokens: Int?
    let ephemeral1hInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case ephemeral5mInputTokens = "ephemeral_5m_input_tokens"
        case ephemeral1hInputTokens = "ephemeral_1h_input_tokens"
    }
}

struct TokenUsageRaw: Decodable, Sendable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?
    let cacheCreation: CacheCreationBreakdown?
    // Per-assistant-message billing speed, sibling of `service_tier` inside the
    // usage block (NOT service_tier). Observed values: "standard", null. A
    // non-standard value signals fast mode and triggers the rate multiplier.
    let speed: String?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheCreation = "cache_creation"
        case speed
    }
}

// MARK: - Tool Use Result

struct ToolUseResultRaw: Decodable, Sendable {
    let toolUseId: String?
    let content: String?
    let isError: Bool?
    // Spawn edge: present on the parent's tool-result record when an Agent/Task
    // tool call spawned a subagent. agentId is the bare hex id of the child.
    let childAgentId: String?
    let childAgentType: String?

    enum CodingKeys: String, CodingKey {
        case toolUseId = "tool_use_id"
        case content
        case isError = "is_error"
        case childAgentId = "agentId"
        case childAgentType = "agentType"
    }
}

// MARK: - File History Snapshot (checkpointing / rewind)

/// The `snapshot` object on a `file-history-snapshot` record. `trackedFileBackups`
/// is keyed by project-relative path; each entry names a backup version under
/// ~/.claude/file-history/<sessionId>/. Keys are already camelCase in the JSONL.
struct FileHistorySnapshotRaw: Decodable, Sendable {
    let messageId: String?
    let timestamp: String?
    let trackedFileBackups: [String: FileBackupRaw]?
}

struct FileBackupRaw: Decodable, Sendable {
    let backupFileName: String?   // null for the v1 baseline
    let version: Int?
    let backupTime: String?
}

// MARK: - Compact Metadata

struct CompactMetadataRaw: Decodable, Sendable {
    let trigger: String?
    let preTokens: Int?
}

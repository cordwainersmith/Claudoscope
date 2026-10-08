import Foundation

enum MinimapEventKind: Sendable, Equatable, Hashable {
    case userTurn
    case assistantTurn
    case toolCall(ToolCategory)
    case toolError
    case blocked
    case compaction
    case subagentSpawn
    case bookmark

    /// Stable key for ids (hashValue is per-process).
    var key: String {
        switch self {
        case .userTurn: return "user"
        case .assistantTurn: return "assistant"
        case .toolCall(let cat): return "tool-\(cat.rawValue)"
        case .toolError: return "error"
        case .blocked: return "blocked"
        case .compaction: return "compaction"
        case .subagentSpawn: return "agent"
        case .bookmark: return "bookmark"
        }
    }
}

struct MinimapEvent: Identifiable, Sendable, Equatable {
    /// Index into `ParsedSession.records`; the chat row anchor is "record-\(recordIndex)".
    let recordIndex: Int
    let uuid: String?
    let kind: MinimapEventKind
    let timestamp: String?
    /// Short label for the hover tooltip: tool name, "Compaction", "Agent: <description>" etc.
    let label: String
    var id: String { "\(recordIndex)-\(kind.key)-\(label)" }
}

enum SessionMinimap {
    /// Pure function over the parsed session. One pass over `session.records.enumerated()`.
    static func events(
        for session: ParsedSession,
        blockedToolUseIds: Set<String>,
        bookmarkedUuids: Set<String> = []
    ) -> [MinimapEvent] {
        var events: [MinimapEvent] = []
        for (index, record) in session.records.enumerated() {
            switch record.type {
            case .user:
                let text = strippedUserText(record.message?.content?.textContent)
                guard !text.isEmpty else { continue }
                events.append(MinimapEvent(
                    recordIndex: index, uuid: record.uuid, kind: .userTurn,
                    timestamp: record.timestamp, label: String(text.prefix(80))
                ))
            case .assistant:
                if record.message?.stopReason != nil {
                    events.append(MinimapEvent(
                        recordIndex: index, uuid: record.uuid, kind: .assistantTurn,
                        timestamp: record.timestamp, label: "Assistant"
                    ))
                }
                guard case .blocks(let blocks) = record.message?.content else { continue }
                for block in blocks where block.type == "tool_use" {
                    guard let name = block.name else { continue }
                    let input = block.input ?? [:]
                    let arg = primaryArgument(from: input, toolName: name)
                    let label = arg.map { "\(name): \($0)" } ?? name
                    events.append(MinimapEvent(
                        recordIndex: index, uuid: record.uuid, kind: .toolCall(toolCategory(for: name)),
                        timestamp: record.timestamp, label: label
                    ))
                    if let id = block.id {
                        if blockedToolUseIds.contains(id) {
                            events.append(MinimapEvent(
                                recordIndex: index, uuid: record.uuid, kind: .blocked,
                                timestamp: record.timestamp, label: "Blocked: \(label)"
                            ))
                        } else if session.toolResultMap[id]?.isError == true {
                            events.append(MinimapEvent(
                                recordIndex: index, uuid: record.uuid, kind: .toolError,
                                timestamp: record.timestamp, label: "Error: \(label)"
                            ))
                        }
                    }
                    if name == "Agent" {
                        let description = input["description"]?.stringValue ?? "subagent"
                        events.append(MinimapEvent(
                            recordIndex: index, uuid: record.uuid, kind: .subagentSpawn,
                            timestamp: record.timestamp, label: "Agent: \(description)"
                        ))
                    }
                }
            case .system:
                if record.subtype == "compact_boundary" {
                    events.append(MinimapEvent(
                        recordIndex: index, uuid: record.uuid, kind: .compaction,
                        timestamp: record.timestamp, label: "Compaction"
                    ))
                }
            default:
                break
            }
            if let uuid = record.uuid, bookmarkedUuids.contains(uuid) {
                events.append(MinimapEvent(
                    recordIndex: index, uuid: uuid, kind: .bookmark,
                    timestamp: record.timestamp, label: "Bookmark"
                ))
            }
        }
        return events
    }

    /// Lane assignment used by the view: 0 = turns, 1 = tools, 2 = markers.
    static func lane(for kind: MinimapEventKind) -> Int {
        switch kind {
        case .userTurn, .assistantTurn: return 0
        case .toolCall: return 1
        case .toolError, .blocked, .compaction, .subagentSpawn, .bookmark: return 2
        }
    }
}

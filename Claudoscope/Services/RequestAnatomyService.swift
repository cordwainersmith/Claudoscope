import Foundation
import OrderedCollections

/// Rebuilds per-request context anatomy for the session Context tab.
///
/// Kept apart from SessionParser for the same reason as FileChangesService:
/// the lite scan skips request-log lines entirely (they are large and are not
/// conversation), so this re-streams the transcript on demand and keeps only
/// sizes, never message text.
actor RequestAnatomyService {

    private var cache = OrderedDictionary<String, (fingerprint: String, anatomy: RequestAnatomy)>()
    private static let cacheCapacity = 4

    func load(url: URL, sessionKey: String) throws -> RequestAnatomy {
        let fingerprint = Self.fingerprint(url)
        if let cached = cache[sessionKey], cached.fingerprint == fingerprint {
            cache.removeValue(forKey: sessionKey)
            cache[sessionKey] = cached
            return cached.anatomy
        }
        let isSubagentFile = url.deletingLastPathComponent().lastPathComponent == "subagents"
        let anatomy = try Self.build(url: url, sessionKey: sessionKey, includeAgentRequests: isSubagentFile)
        cache.removeValue(forKey: sessionKey)
        cache[sessionKey] = (fingerprint, anatomy)
        while cache.count > Self.cacheCapacity { cache.removeFirst() }
        return anatomy
    }

    private static func fingerprint(_ url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? -1
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(url.lastPathComponent):\(size):\(mtime)"
    }

    // MARK: - Build

    private struct ToolSize {
        let name: String
        let bytes: Int
        let deferred: Bool
        var mcpServer: String? { RequestAnatomyService.mcpServer(of: name) }
    }

    private struct Shape {
        let systemBytes: Int
        let tools: [ToolSize]
    }

    private struct BlobSize {
        let reminderBytes: Int
        let conversationBytes: Int
    }

    private struct Request {
        let id: String
        let timestamp: String
        let querySource: String
        let shapeHash: String?
        let model: String?
        let effort: String?
        let messages: [Int32]
        let complete: Bool
    }

    private struct Usage {
        let total: Int
        let final: Bool
    }

    static func build(url: URL, sessionKey: String, includeAgentRequests: Bool) throws -> RequestAnatomy {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            return RequestAnatomy(sessionKey: sessionKey, points: [], latest: nil, peak: nil)
        }
        defer { handle.closeFile() }

        var shapes: [String: Shape] = [:]
        var blobIndex: [String: Int32] = [:]
        var blobs: [BlobSize] = []
        var requests: [Request] = []
        var messagesById: [String: [Int32]] = [:]
        var usageByRequest: [String: Usage] = [:]
        let decoder = JSONDecoder()

        for line in StreamingLineReader(fileHandle: handle) {
            try Task.checkCancellation()
            if SessionParser.isRequestLogLine(line) {
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      let type = obj["type"] as? String else { continue }
                switch type {
                case "api-request-shape":
                    if let hash = obj["shapeHash"] as? String, let shape = obj["shape"] as? [String: Any] {
                        shapes[hash] = parseShape(shape)
                    }
                case "api-request-blob":
                    if let hash = obj["hash"] as? String, blobIndex[hash] == nil,
                       let message = obj["message"] as? [String: Any] {
                        blobIndex[hash] = Int32(blobs.count)
                        blobs.append(sizeBlob(message))
                    }
                case "api-request":
                    guard let id = obj["id"] as? String else { continue }
                    let tail = (obj["tail"] as? [String] ?? []).map { blobIndex[$0] ?? -1 }
                    let keep = intValue(obj["keep"]) ?? 0
                    var complete = !tail.contains(-1)
                    var messages: [Int32]
                    if let base = obj["base"] as? String {
                        if let prior = messagesById[base] {
                            messages = Array(prior.prefix(keep)) + tail
                        } else {
                            messages = tail
                            complete = false
                        }
                    } else {
                        messages = tail
                    }
                    messagesById[id] = messages
                    let params = obj["params"] as? [String: Any]
                    let outputConfig = params?["output_config"] as? [String: Any]
                    requests.append(Request(
                        id: id,
                        timestamp: obj["timestamp"] as? String ?? "",
                        querySource: obj["querySource"] as? String ?? "",
                        shapeHash: obj["shapeHash"] as? String,
                        model: params?["model"] as? String,
                        effort: outputConfig?["effort"] as? String,
                        messages: messages,
                        complete: complete
                    ))
                default:
                    continue
                }
            } else if line.contains("\"requestRef\":\"") {
                guard let rec = try? decoder.decode(AssistantRef.self, from: Data(line.utf8)),
                      rec.type == "assistant", let ref = rec.requestRef, let usage = rec.message?.usage else { continue }
                let total = (usage.input_tokens ?? 0) + (usage.cache_read_input_tokens ?? 0)
                    + (usage.cache_creation_input_tokens ?? 0)
                let isFinal = rec.message?.stop_reason != nil
                // The final record of a stream carries the request's real usage;
                // keep the first final one, else the latest partial.
                if let existing = usageByRequest[ref], existing.final { continue }
                usageByRequest[ref] = Usage(total: total, final: isFinal)
            }
        }

        let own = requests.filter { includeAgentRequests || !$0.querySource.hasPrefix("agent") }

        // Bytes per category for each request. Claude Code writes a blob line
        // only for content that is not already a transcript record (system
        // messages, reminders); ordinary prompts, replies and tool results are
        // referenced by hash alone, so those count as unknown conversation.
        struct Sized {
            let request: Request
            let shape: Shape?
            let bytes: [AnatomyCategory: Int]
            let deferredCount: Int
            let hasUnknownMessages: Bool
        }
        let sized: [Sized] = own.map { request in
            let shape = request.shapeHash.flatMap { shapes[$0] }
            var bytes: [AnatomyCategory: Int] = [:]
            bytes[.system] = shape?.systemBytes ?? 0
            var deferredCount = 0
            for tool in shape?.tools ?? [] {
                if tool.deferred {
                    deferredCount += 1
                } else if tool.mcpServer != nil {
                    bytes[.mcpTools, default: 0] += tool.bytes
                } else {
                    bytes[.builtinTools, default: 0] += tool.bytes
                }
            }
            var unknown = !request.complete
            for index in request.messages {
                guard index >= 0 else { unknown = true; continue }
                let blob = blobs[Int(index)]
                bytes[.reminders, default: 0] += blob.reminderBytes
                bytes[.conversation, default: 0] += blob.conversationBytes
            }
            return Sized(request: request, shape: shape, bytes: bytes, deferredCount: deferredCount,
                         hasUnknownMessages: unknown)
        }

        // Tokens per byte, calibrated on requests whose every part is known and
        // whose real input size is recorded. Falls back to ~4 bytes per token.
        let calibration: [Double] = sized.compactMap { item in
            guard !item.hasUnknownMessages, item.shape != nil,
                  let usage = usageByRequest[item.request.id] else { return nil }
            let loaded = item.bytes.values.reduce(0, +)
            return loaded > 0 ? Double(usage.total) / Double(loaded) : nil
        }.sorted()
        let tokensPerByte = calibration.isEmpty ? 0.25 : calibration[calibration.count / 2]

        var points: [AnatomyPoint] = []
        var details: [String: (shape: Shape?, ratio: Double)] = [:]
        for item in sized {
            let usage = usageByRequest[item.request.id]
            var tokens: [AnatomyCategory: Int] = [:]
            var ratio = tokensPerByte
            if let usage, !item.hasUnknownMessages, item.shape != nil, item.bytes.values.reduce(0, +) > 0 {
                // Every part known: split the real total by size.
                ratio = Double(usage.total) / Double(item.bytes.values.reduce(0, +))
                for category in AnatomyCategory.allCases {
                    tokens[category] = Int((Double(item.bytes[category, default: 0]) * ratio).rounded())
                }
            } else {
                for category in AnatomyCategory.allCases where category != .conversation {
                    tokens[category] = Int((Double(item.bytes[category, default: 0]) * ratio).rounded())
                }
                let fixed = tokens.values.reduce(0, +)
                if let usage {
                    if fixed > usage.total, fixed > 0 {
                        // Calibration overshot this request: scale the known parts
                        // down to fit the real total.
                        let scale = Double(usage.total) / Double(fixed)
                        for (category, value) in tokens { tokens[category] = Int((Double(value) * scale).rounded()) }
                        ratio *= scale
                        tokens[.conversation] = 0
                    } else {
                        tokens[.conversation] = usage.total - fixed
                    }
                } else {
                    tokens[.conversation] = Int((Double(item.bytes[.conversation, default: 0]) * ratio).rounded())
                }
            }
            points.append(AnatomyPoint(
                id: item.request.id,
                timestamp: item.request.timestamp,
                querySource: item.request.querySource,
                model: item.request.model,
                effort: item.request.effort,
                bytes: item.bytes,
                deferredToolCount: item.deferredCount,
                tokens: tokens,
                isMeasured: usage != nil && item.shape != nil
            ))
            details[item.request.id] = (item.shape, ratio)
        }

        func detail(for point: AnatomyPoint?) -> AnatomyDetail? {
            guard let point, let info = details[point.id] else { return nil }
            var servers: [String: (tokens: Int, count: Int)] = [:]
            var tools: [AnatomyToolRow] = []
            for tool in info.shape?.tools ?? [] where !tool.deferred {
                let tokens = Int((Double(tool.bytes) * info.ratio).rounded())
                tools.append(AnatomyToolRow(name: tool.name, tokens: tokens))
                if let server = tool.mcpServer {
                    var entry = servers[server] ?? (0, 0)
                    entry.tokens += tokens
                    entry.count += 1
                    servers[server] = entry
                }
            }
            return AnatomyDetail(
                point: point,
                mcpByServer: servers
                    .map { AnatomyServerRow(server: $0.key, tokens: $0.value.tokens, toolCount: $0.value.count) }
                    .sorted { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.server < $1.server },
                topTools: Array(tools.sorted { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.name < $1.name }.prefix(10))
            )
        }

        let peak = points.max { $0.totalTokens < $1.totalTokens }
        return RequestAnatomy(
            sessionKey: sessionKey,
            points: points,
            latest: detail(for: points.last),
            peak: detail(for: peak)
        )
    }

    // MARK: - Sizing

    private static func parseShape(_ shape: [String: Any]) -> Shape {
        var systemBytes = 0
        for block in shape["system"] as? [[String: Any]] ?? [] {
            systemBytes += (block["text"] as? String)?.utf8.count ?? jsonSize(block)
        }
        let tools = (shape["tools"] as? [[String: Any]] ?? []).map { tool in
            ToolSize(
                name: tool["name"] as? String ?? "?",
                bytes: jsonSize(tool),
                deferred: tool["defer_loading"] as? Bool ?? false
            )
        }
        return Shape(systemBytes: systemBytes, tools: tools)
    }

    /// System-role messages (hook context, environment updates) and the
    /// `<system-reminder>` text blocks Claude Code puts in user messages
    /// (CLAUDE.md, rules, skill lists) count as instructions; everything else,
    /// tool calls and results included, is conversation.
    private static func sizeBlob(_ message: [String: Any]) -> BlobSize {
        let role = message["role"] as? String
        var reminder = 0
        var conversation = 0
        func add(_ bytes: Int, isReminder: Bool) {
            if isReminder { reminder += bytes } else { conversation += bytes }
        }
        if let text = message["content"] as? String {
            add(text.utf8.count, isReminder: role == "system" || text.hasPrefix("<system-reminder>"))
        } else {
            for block in message["content"] as? [[String: Any]] ?? [] {
                if block["type"] as? String == "text", let text = block["text"] as? String {
                    add(text.utf8.count, isReminder: role == "system" || text.hasPrefix("<system-reminder>"))
                } else {
                    add(jsonSize(block), isReminder: role == "system")
                }
            }
        }
        return BlobSize(reminderBytes: reminder, conversationBytes: conversation)
    }

    private static func jsonSize(_ value: Any) -> Int {
        (try? JSONSerialization.data(withJSONObject: value))?.count ?? 0
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let s = value as? String { return Int(s) }
        return nil
    }

    /// `mcp__<server>__<tool>`: the server segment, or nil for a built-in tool.
    static func mcpServer(of toolName: String) -> String? {
        guard toolName.hasPrefix("mcp__") else { return nil }
        let rest = toolName.dropFirst("mcp__".count)
        guard let range = rest.range(of: "__") else { return String(rest) }
        return String(rest[..<range.lowerBound])
    }

    // MARK: - Lenient assistant decode

    private struct AssistantRef: Decodable {
        let type: String?
        let requestRef: String?
        let message: Message?

        struct Message: Decodable {
            let stop_reason: String?
            let usage: UsageRaw?

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                stop_reason = try? c.decodeIfPresent(String.self, forKey: .stop_reason)
                usage = try? c.decodeIfPresent(UsageRaw.self, forKey: .usage)
            }
            enum CodingKeys: String, CodingKey { case stop_reason, usage }
        }

        struct UsageRaw: Decodable {
            let input_tokens: Int?
            let cache_read_input_tokens: Int?
            let cache_creation_input_tokens: Int?
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            requestRef = try? c.decodeIfPresent(String.self, forKey: .requestRef)
            message = try? c.decodeIfPresent(Message.self, forKey: .message)
        }
        enum CodingKeys: String, CodingKey { case type, requestRef, message }
    }
}

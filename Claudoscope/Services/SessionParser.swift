import Foundation

/// Stream-parses Claude Code JSONL session files.
/// Port of server/services/session-parser.ts
actor SessionParser {
    private let decoder = JSONDecoder()

    /// Full parse of a JSONL session file into a ParsedSession
    func parse(url: URL, sessionId: String) throws -> ParsedSession {
        guard let fileHandle = FileHandle(forReadingAtPath: url.path) else {
            throw SessionParserError.fileNotFound
        }
        defer { fileHandle.closeFile() }

        var records: [ParsedRecordRaw] = []
        var toolResultMap: [String: ToolResultEntry] = [:]
        var modelsSet = Set<String>()

        var firstTimestamp = ""
        var lastTimestamp = ""
        var messageCount = 0
        var userMessageCount = 0
        var assistantMessageCount = 0
        var totalInputTokens = 0
        var totalOutputTokens = 0
        var totalCacheReadTokens = 0
        var totalCacheCreationTokens = 0
        var compactionCount = 0
        var parentSessionId: String?
        var slug: String?
        var isFirstRecord = true
        var projectId = ""

        for line in StreamingLineReader(fileHandle: fileHandle) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            guard let lineData = trimmed.data(using: .utf8) else { continue }

            let record: ParsedRecordRaw
            do {
                record = try decoder.decode(ParsedRecordRaw.self, from: lineData)
            } catch {
                continue // Skip malformed lines
            }

            // Detect continuation
            if isFirstRecord {
                isFirstRecord = false
                if let recSessionId = record.sessionId, recSessionId != sessionId {
                    parentSessionId = recSessionId
                }
            }

            // Skip records from parent session
            if let parentId = parentSessionId, record.sessionId == parentId {
                continue
            }

            // Skip compact summaries, progress, transcript-only
            if record.isCompactSummary == true { continue }
            if record.type == .progress { continue }
            if record.isVisibleInTranscriptOnly == true { continue }

            // Capture slug — keep the latest non-empty one. Claude Code rewrites the
            // random initial slug to a meaningful one as work progresses (or when the
            // user runs /rename), so the last record wins.
            if let s = record.slug, !s.isEmpty {
                slug = s
            }

            // Track timestamps
            if let ts = record.timestamp {
                if firstTimestamp.isEmpty { firstTimestamp = ts }
                lastTimestamp = ts
            }

            messageCount += 1

            if record.type == .user {
                userMessageCount += 1
            }

            if record.type == .assistant {
                assistantMessageCount += 1

                if record.message?.stopReason != nil, let usage = record.message?.usage {
                    totalInputTokens += usage.inputTokens ?? 0
                    totalOutputTokens += usage.outputTokens ?? 0
                    totalCacheReadTokens += usage.cacheReadInputTokens ?? 0
                    totalCacheCreationTokens += usage.cacheCreationInputTokens ?? 0
                }

                if let model = record.message?.model {
                    modelsSet.insert(model)
                }
            }

            // Compaction boundaries
            if record.type == .system && record.subtype == "compact_boundary" {
                compactionCount += 1
            }

            // Build tool result map from top-level tool_result records.
            // First-write-wins: top-level and embedded forms can disagree on isError/content shape.
            if record.type == .toolResult, let toolUseId = record.toolUseResult?.toolUseId,
               toolResultMap[toolUseId] == nil {
                toolResultMap[toolUseId] = ToolResultEntry(
                    content: record.toolUseResult?.content ?? "",
                    isError: record.toolUseResult?.isError ?? false,
                    timestamp: record.timestamp
                )
            }

            // Extract tool_result blocks embedded in user message content arrays
            if record.type == .user, case .blocks(let blocks) = record.message?.content {
                for block in blocks {
                    if block.type == "tool_result", let toolUseId = block.toolUseId,
                       toolResultMap[toolUseId] == nil {
                        let resultText: String
                        if let content = block.content {
                            resultText = content.textContent
                        } else {
                            resultText = ""
                        }
                        toolResultMap[toolUseId] = ToolResultEntry(
                            content: resultText,
                            isError: block.isError ?? false,
                            timestamp: record.timestamp
                        )
                    }
                }
            }

            records.append(record)
        }

        // Derive projectId from file path
        let pathComponents = url.pathComponents
        if let projectsIndex = pathComponents.lastIndex(of: "projects"),
           projectsIndex + 1 < pathComponents.count {
            projectId = pathComponents[projectsIndex + 1]
        }

        let metadata = SessionMetadata(
            firstTimestamp: firstTimestamp,
            lastTimestamp: lastTimestamp,
            messageCount: messageCount,
            userMessageCount: userMessageCount,
            assistantMessageCount: assistantMessageCount,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            totalCacheReadTokens: totalCacheReadTokens,
            totalCacheCreationTokens: totalCacheCreationTokens,
            models: Array(modelsSet),
            compactionCount: compactionCount,
            turnDurations: [],
            effortDistribution: .zero,
            maxIdleGapSeconds: 0,
            idleGapAfterTimestamp: nil,
            compactionEvents: [],
            parallelToolGroups: [],
            errorDetails: []
        )

        return ParsedSession(
            id: sessionId,
            projectId: projectId,
            slug: slug,
            records: records,
            toolResultMap: toolResultMap,
            metadata: metadata,
            parentSessionId: parentSessionId
        )
    }

    /// Extract the concatenated text content from a lightweight content value.
    /// Used to surface real error messages to the error classifier and sidebar.
    private func extractText(from content: MetadataOnlyContent?) -> String {
        switch content {
        case .string(let s):
            return s
        case .blocks(let blocks):
            return blocks.compactMap { $0.text }.joined(separator: " ")
        case .none:
            return ""
        }
    }

    /// Quick metadata extraction for sidebar listing
    func parseMetadata(url: URL, sessionId: String, pricingTable: [String: ModelPricing]) throws -> SessionSummary {
        // Stream-parse line by line to avoid loading entire file into memory.
        // Large session directories (thousands of files, 1GB+) caused the app to
        // peg the CPU at 100% when every file was fully loaded during initial scan.
        guard let fileHandle = FileHandle(forReadingAtPath: url.path) else {
            throw SessionParserError.fileNotFound
        }
        defer { fileHandle.closeFile() }

        // Bug fix: use local dedup set instead of actor-level seenUUIDs
        // to avoid cross-session dedup that causes costs to drop to $0 over time
        var localSeenUUIDs = Set<String>()

        let projectId = deriveProjectId(from: url)
        var lineCount = 0
        var totalInputTokens = 0
        var totalOutputTokens = 0
        var totalCacheReadTokens = 0
        var totalCacheCreationTokens = 0
        var totalCacheCreation5mTokens = 0
        var totalCacheCreation1hTokens = 0
        var modelOutputTokens: [String: Int] = [:]
        var hasError = false
        var slug: String?
        var customTitle: String?
        var isFirstRecord = true
        var parentSessionId: String? = nil
        var firstTimestamp = ""
        var lastTimestamp = ""
        var firstLine = ""
        var perMessageCost = 0.0
        var compactionCount = 0
        var toolCallCount = 0

        // Per-model breakdown accumulators
        var modelInputTokens: [String: Int] = [:]
        var modelCacheReadTokens: [String: Int] = [:]
        var modelCost: [String: Double] = [:]
        var modelTurnCount: [String: Int] = [:]

        // Observability tracking
        var turnDurations: [TurnDuration] = []
        var effortCounts: [EffortLevel: Int] = [:]
        var errorDetails: [SessionErrorDetail] = []
        var compactionEvents: [CompactionEvent] = []
        var parallelToolGroups: [ParallelToolGroup] = []
        var lastUserTimestamp: String?
        var turnIndex = 0
        var hadCompactionSinceLast = false
        var turnsSinceLastCompaction = 0
        var hasWorktreeTool = false
        var recordTimestamps: [String] = []

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFormatterNoFrac = ISO8601DateFormatter()
        isoFormatterNoFrac.formatOptions = [.withInternetDateTime]

        for line in StreamingLineReader(fileHandle: fileHandle) {
            try Task.checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            lineCount += 1

            if lineCount == 1 {
                firstLine = trimmed
            }

            guard let lineData = trimmed.data(using: .utf8) else { continue }

            do {
                let raw = try decoder.decode(MetadataOnlyRecord.self, from: lineData)

                if raw.isCompactSummary == true || raw.type == .progress || raw.isVisibleInTranscriptOnly == true {
                    continue
                }

                if let ts = raw.timestamp {
                    if firstTimestamp.isEmpty { firstTimestamp = ts }
                    lastTimestamp = ts
                }

                if isFirstRecord {
                    isFirstRecord = false
                    if let recSessionId = raw.sessionId, recSessionId != sessionId {
                        parentSessionId = recSessionId
                    }
                }
                if let parentId = parentSessionId, raw.sessionId == parentId {
                    continue
                }
                if let s = raw.slug, !s.isEmpty {
                    slug = s
                }
                // /rename writes type:"custom-title" / "agent-name" records that carry
                // these fields; either one is the user's chosen display name. Last wins.
                if let t = raw.customTitle ?? raw.agentName, !t.isEmpty {
                    customTitle = t
                }

                // Track user timestamps for turn duration computation
                if raw.type == .user {
                    lastUserTimestamp = raw.timestamp
                }

                if raw.type == .assistant {
                    // Count tool_use blocks for tool call count, and sum thinking chars
                    var turnToolNames: [String] = []
                    var turnThinkingChars = 0
                    if case .blocks(let blocks) = raw.message?.content {
                        let toolUseBlocks = blocks.filter { $0.type == "tool_use" }
                        toolCallCount += toolUseBlocks.count
                        turnToolNames = toolUseBlocks.compactMap(\.name)
                        if !hasWorktreeTool && turnToolNames.contains(where: { $0 == "EnterWorktree" || $0 == "ExitWorktree" }) {
                            hasWorktreeTool = true
                        }
                        for block in blocks where block.type == "thinking" {
                            turnThinkingChars += block.thinking?.count ?? 0
                        }
                    }

                    if raw.message?.stopReason != nil, let usage = raw.message?.usage {
                        // Deduplicate: skip records already counted from another file
                        if let uuid = raw.uuid {
                            if localSeenUUIDs.contains(uuid) { continue }
                            localSeenUUIDs.insert(uuid)
                        }

                        let msgInput = usage.inputTokens ?? 0
                        let msgOutput = usage.outputTokens ?? 0
                        let msgCacheRead = usage.cacheReadInputTokens ?? 0
                        let msgCacheCreate = usage.cacheCreationInputTokens ?? 0

                        // The breakdown object is often present but with no sub-fields
                        // populated; in that case the legacy total is authoritative and
                        // attributed to the default 5m tier. Only when the breakdown has
                        // at least one explicit sub-field do we trust it over the total
                        // (this is the case the audit's "double-count" warned about).
                        let breakdown5m = usage.cacheCreation?.ephemeral5mInputTokens
                        let breakdown1h = usage.cacheCreation?.ephemeral1hInputTokens
                        let msgCache5m: Int
                        let msgCache1h: Int
                        if breakdown5m != nil || breakdown1h != nil {
                            msgCache5m = breakdown5m ?? 0
                            msgCache1h = breakdown1h ?? 0
                        } else {
                            msgCache5m = msgCacheCreate
                            msgCache1h = 0
                        }

                        totalInputTokens += msgInput
                        totalOutputTokens += msgOutput
                        totalCacheReadTokens += msgCacheRead
                        totalCacheCreationTokens += msgCacheCreate
                        totalCacheCreation5mTokens += msgCache5m
                        totalCacheCreation1hTokens += msgCache1h

                        // Accumulate cost per-message using each message's actual model
                        let msgCost = estimateCostFromTokens(
                            model: raw.message?.model,
                            inputTokens: msgInput,
                            outputTokens: msgOutput,
                            cacheReadTokens: msgCacheRead,
                            cacheCreation5mTokens: msgCache5m,
                            cacheCreation1hTokens: msgCache1h,
                            table: pricingTable
                        )
                        perMessageCost += msgCost

                        if let model = raw.message?.model {
                            let family = getModelFamily(model)
                            modelOutputTokens[model, default: 0] += msgOutput
                            modelInputTokens[family, default: 0] += msgInput
                            modelCacheReadTokens[family, default: 0] += msgCacheRead
                            modelCost[family, default: 0] += msgCost
                            modelTurnCount[family, default: 0] += 1
                        }

                        // Observability: compute turn duration
                        var durationMs: Double = 0
                        if let userTs = lastUserTimestamp, let assistantTs = raw.timestamp {
                            let userDate = isoFormatter.date(from: userTs) ?? isoFormatterNoFrac.date(from: userTs)
                            let assistantDate = isoFormatter.date(from: assistantTs) ?? isoFormatterNoFrac.date(from: assistantTs)
                            if let ud = userDate, let ad = assistantDate {
                                durationMs = max(0, ad.timeIntervalSince(ud) * 1000)
                            }
                        }

                        turnDurations.append(TurnDuration(
                            turnIndex: turnIndex,
                            userTimestamp: lastUserTimestamp,
                            assistantTimestamp: raw.timestamp,
                            durationMs: durationMs,
                            isPostCompaction: hadCompactionSinceLast,
                            inputTokens: msgInput,
                            model: raw.message?.model
                        ))

                        let effort = ObservabilityAnalyzer.classifyEffort(
                            thinkingChars: turnThinkingChars,
                            outputTokens: msgOutput,
                            stopReason: raw.message?.stopReason
                        )
                        effortCounts[effort, default: 0] += 1

                        // Observability: parallel tool groups (more than 1 tool_use in one turn)
                        if turnToolNames.count > 1 {
                            parallelToolGroups.append(ParallelToolGroup(
                                turnIndex: turnIndex,
                                timestamp: raw.timestamp,
                                toolNames: turnToolNames,
                                toolCount: turnToolNames.count
                            ))
                        }

                        turnIndex += 1
                        turnsSinceLastCompaction += 1
                        lastUserTimestamp = nil
                    }
                }

                if raw.type == .result, raw.message?.stopReason == "error" {
                    hasError = true
                    let messageText = extractText(from: raw.message?.content)
                    let contentText = messageText.isEmpty ? (raw.content ?? "") : messageText
                    let classification = ObservabilityAnalyzer.classifyError(
                        contentText: contentText,
                        stopReason: raw.message?.stopReason
                    )
                    errorDetails.append(SessionErrorDetail(
                        classification: classification,
                        turnIndex: turnIndex,
                        timestamp: raw.timestamp,
                        message: contentText.isEmpty ? "error" : contentText
                    ))
                }

                if raw.type == .toolResult, raw.toolUseResult?.isError == true {
                    hasError = true
                    let contentText = raw.toolUseResult?.content ?? ""
                    errorDetails.append(SessionErrorDetail(
                        classification: .toolError,
                        turnIndex: turnIndex,
                        timestamp: raw.timestamp,
                        message: contentText.isEmpty ? "tool error" : contentText
                    ))
                }

                if raw.type == .system && raw.subtype == "compact_boundary" {
                    compactionCount += 1
                    compactionEvents.append(CompactionEvent(
                        index: compactionCount,
                        timestamp: raw.timestamp,
                        preTokens: raw.compactMetadata?.preTokens,
                        turnsSinceLastCompaction: turnsSinceLastCompaction
                    ))
                    hadCompactionSinceLast = true
                    turnsSinceLastCompaction = 0
                }

                if let ts = raw.timestamp { recordTimestamps.append(ts) }
            } catch {
                continue
            }
        }

        let title = deriveTitle(customTitle: customTitle, slug: slug, firstLine: firstLine, sessionId: sessionId)
        let primaryModel = modelOutputTokens.max(by: { $0.value < $1.value })?.key

        // Build model breakdown
        let allFamilies = Set(modelTurnCount.keys)
        let modelBreakdown = allFamilies.map { family in
            ModelTokenBreakdown(
                model: family,
                inputTokens: modelInputTokens[family, default: 0],
                outputTokens: modelOutputTokens.filter { getModelFamily($0.key) == family }.values.reduce(0, +),
                cacheReadTokens: modelCacheReadTokens[family, default: 0],
                estimatedCost: modelCost[family, default: 0],
                turnCount: modelTurnCount[family, default: 0]
            )
        }.sorted { $0.estimatedCost > $1.estimatedCost }

        // Compute idle gap detection from collected timestamps
        let idleGapResult = ObservabilityAnalyzer.detectIdleGaps(timestamps: recordTimestamps)

        // Compute session observability
        let observability = ObservabilityAnalyzer.computeObservability(
            turnDurations: turnDurations,
            effortCounts: effortCounts,
            errorDetails: errorDetails,
            idleGapResult: idleGapResult,
            compactionEvents: compactionEvents,
            parallelToolGroups: parallelToolGroups,
            isWorktreeSession: hasWorktreeTool
        )

        return SessionSummary(
            id: sessionId,
            projectId: projectId,
            slug: slug,
            title: title,
            firstTimestamp: firstTimestamp,
            lastTimestamp: lastTimestamp,
            messageCount: lineCount,
            primaryModel: primaryModel,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            totalCacheReadTokens: totalCacheReadTokens,
            totalCacheCreationTokens: totalCacheCreationTokens,
            totalCacheCreation5mTokens: totalCacheCreation5mTokens,
            totalCacheCreation1hTokens: totalCacheCreation1hTokens,
            compactionCount: compactionCount,
            estimatedCost: perMessageCost,
            hasError: hasError,
            modelBreakdown: modelBreakdown,
            toolCallCount: toolCallCount,
            observability: observability
        )
    }

    private func deriveProjectId(from url: URL) -> String {
        let components = url.pathComponents
        if let idx = components.lastIndex(of: "projects"), idx + 1 < components.count {
            return components[idx + 1]
        }
        return "unknown"
    }

    private func deriveTitle(customTitle: String?, slug: String?, firstLine: String, sessionId: String) -> String {
        // /rename (writes a custom-title record) takes precedence over the slug,
        // since the slug field is never updated when the user renames a session.
        if let customTitle { return customTitle }
        if let slug { return slug }

        if let data = firstLine.data(using: .utf8),
           let raw = try? decoder.decode(ParsedRecordRaw.self, from: data),
           raw.type == .user,
           let content = raw.message?.content {

            let text = content.textContent
            if !text.isEmpty {
                let cleaned = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                if cleaned.count > 80 {
                    return String(cleaned.prefix(80)) + "..."
                }
                return cleaned
            }
        }

        return String(sessionId.prefix(8))
    }
}

enum SessionParserError: Error {
    case invalidEncoding
    case fileNotFound
}

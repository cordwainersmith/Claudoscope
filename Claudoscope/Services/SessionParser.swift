import Foundation

/// Per-day accumulators used while parsing a session's billed messages. Mutable
/// structs held in a `[localDay: DayAcc]` map; the parser derives the immutable
/// `DailyContribution`s and the lump totals from them at the end, so there is a
/// single source of truth and the two can never disagree.
private struct ModelDayAcc {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var estimatedCost = 0.0
    var turnCount = 0
}

private struct DayAcc {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheCreationTokens = 0
    var cacheCreation5mTokens = 0
    var cacheCreation1hTokens = 0
    var estimatedCost = 0.0
    var model: [String: ModelDayAcc] = [:]
}

/// Stream-parses Claude Code JSONL session files.
/// Port of server/services/session-parser.ts
actor SessionParser {
    /// Version stamp for the persistent summary cache (SessionSummaryStore).
    /// Cached SessionSummary blobs are valid only while this matches the value
    /// stored in the cache's meta table; a mismatch wipes the cache and
    /// reparses everything on next launch. BUMP THIS when any of the following
    /// change, or users silently keep stale numbers:
    ///  (a) parse/billing/dedup logic (orphan billing, sidechain handling,
    ///      context-fork stripping, usage accumulation, stop_reason handling)
    ///  (b) any field on SessionSummary or its nested types (an added field
    ///      makes old blobs undecodable, which degrades into a silent full
    ///      reparse; the bump makes the wipe explicit)
    ///  (c) getModelFamily detection regexes (they steer pricing lookup)
    /// Pricing rate-table edits do NOT need a bump: rates are hashed into the
    /// cache's pricing key. See docs/sqlite-persistence-roadmap.md, section 9.
    static let parserVersion: Int = 1

    private let liteDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.userInfo[.decodeMode] = DecodeMode.lite
        return d
    }()
    private let fullDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.userInfo[.decodeMode] = DecodeMode.full
        return d
    }()

    /// Cache of a parent transcript's billable assistant `message.id`s, keyed by
    /// the parent file path and validated by mtime. Used to strip parent-replayed
    /// records out of context-forking subagent files (auto-compact / aside) so
    /// their copied usage blocks aren't billed twice.
    private var parentMsgIdCache: [String: (mtime: Date, ids: Set<String>)] = [:]
    private static let parentMsgIdCacheLimit = 16

    /// Collects every `message.id` whose record carries `stop_reason`, used to
    /// distinguish ordinary streaming intermediates (dropped because the
    /// stop_reason record carries cumulative usage) from "orphan" records
    /// whose stream never produced a stop_reason record (aborted streams,
    /// transcript truncation, crashes). Anthropic still bills orphan calls,
    /// so we count one record per orphan msg.id.
    ///
    /// The set is now derived from an in-memory list of records: `parse` and
    /// `parseMetadata` stream the file once into a buffer, then call this.
    /// Previously this re-read the entire file from disk, doubling I/O.
    private func collectStopReasonMessageIds(_ records: [ParsedRecordRaw]) -> Set<String> {
        var ids = Set<String>()
        for raw in records {
            if raw.type == .assistant,
               let msg = raw.message,
               msg.stopReason != nil,
               let id = msg.id {
                ids.insert(id)
            }
        }
        return ids
    }

    /// For each orphan msg.id (no stop_reason record anywhere in the file),
    /// pick the index of the record carrying the LARGEST cumulative usage.
    /// Aborted streams persist several intermediates sharing one msg.id with
    /// growing usage; the final, largest record is the one Anthropic billed.
    /// Records without a msg.id never enter the map, so they stay billed
    /// individually by the existing per-record path. Ties resolve to the LAST
    /// occurrence (`>=`), matching the stream's final write.
    private func selectOrphanBillingIndices(
        _ records: [ParsedRecordRaw],
        stopReasonMsgIds: Set<String>
    ) -> [String: Int] {
        var chosen: [String: Int] = [:]
        var bestTotal: [String: Int] = [:]
        for (idx, raw) in records.enumerated() {
            guard raw.type == .assistant,
                  let msg = raw.message,
                  let id = msg.id,
                  !stopReasonMsgIds.contains(id),
                  let usage = msg.usage else { continue }
            let total = (usage.inputTokens ?? 0) + (usage.outputTokens ?? 0)
                + (usage.cacheReadInputTokens ?? 0) + (usage.cacheCreationInputTokens ?? 0)
            if let prev = bestTotal[id], total < prev { continue }
            bestTotal[id] = total
            chosen[id] = idx
        }
        return chosen
    }

    /// Context-forking subagent transcripts (auto-compact, aside questions)
    /// replay the parent's history verbatim — same msg.ids, same usage blocks —
    /// before issuing their one genuinely new API call. Ordinary `agent-<hash>`
    /// subagents do not, so the prefix gate is deliberately narrow.
    /// Internal (not private): the summary cache fingerprints these files with
    /// their parent's stat as well, and must use the exact same gate.
    static func isContextForkFilename(_ fileName: String) -> Bool {
        fileName.hasPrefix("agent-acompact-") || fileName.hasPrefix("agent-aside_question-")
    }

    /// True for a context-forking subagent file in its canonical location
    /// (`.../subagents/agent-acompact-*` or `agent-aside_question-*`). The
    /// cache fingerprints these files with their parent transcript's stat as
    /// well; this is the shared gate for that decision.
    static func isContextForkSubagentFile(_ url: URL) -> Bool {
        url.deletingLastPathComponent().lastPathComponent == "subagents"
            && isContextForkFilename(url.lastPathComponent)
    }

    /// Parent transcript URL for a subagent file at
    /// `<project>/<parentUuid>/subagents/<sub>.jsonl`: the parent lives at
    /// `<project>/<parentUuid>.jsonl`. Shared with the scanner's cache
    /// fingerprinting so the two can never disagree on the parent path.
    static func parentTranscriptURL(forSubagentFile url: URL) -> URL {
        url.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathExtension("jsonl")
    }

    /// Billable assistant msg.ids of the parent transcript for a subagent file
    /// at `<project>/<parentUuid>/subagents/<sub>.jsonl`. The parent lives at
    /// `<project>/<parentUuid>.jsonl`. Synchronous on purpose: the actor's
    /// reentrancy safety depends on no `await` between the dedup decision and
    /// the seen-id inserts in the billing loops.
    private func parentAssistantMessageIds(forSubagentFileAt url: URL) -> Set<String> {
        let parentURL = Self.parentTranscriptURL(forSubagentFile: url)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: parentURL.path),
              let mtime = attrs[.modificationDate] as? Date else {
            // Parent missing or unreadable: don't cache, so a parent that
            // appears later (or is rewritten) is picked up on the next parse.
            return []
        }
        if let cached = parentMsgIdCache[parentURL.path], cached.mtime == mtime {
            return cached.ids
        }
        guard let handle = FileHandle(forReadingAtPath: parentURL.path) else { return [] }
        defer { handle.closeFile() }
        var ids = Set<String>()
        for line in StreamingLineReader(fileHandle: handle) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8),
                  let raw = try? liteDecoder.decode(ParsedRecordRaw.self, from: data) else { continue }
            if raw.type == .assistant, let msg = raw.message, msg.usage != nil, let id = msg.id {
                ids.insert(id)
            }
        }
        if parentMsgIdCache.count >= Self.parentMsgIdCacheLimit { parentMsgIdCache.removeAll() }
        parentMsgIdCache[parentURL.path] = (mtime, ids)
        return ids
    }

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
        var seenMessageIds = Set<String>()
        let isSubagentFile = url.deletingLastPathComponent().lastPathComponent == "subagents"

        // Phase 1: stream-decode the file once into a buffer. No filtering here
        // so phase 2's stop-reason set sees the exact same records the legacy
        // two-pass version did.
        var bufferedRecords: [ParsedRecordRaw] = []
        for line in StreamingLineReader(fileHandle: fileHandle) {
            try Task.checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let lineData = trimmed.data(using: .utf8) else { continue }
            guard let raw = try? fullDecoder.decode(ParsedRecordRaw.self, from: lineData) else {
                continue
            }
            bufferedRecords.append(raw)
        }

        // Phase 2: derive stop-reason set from the buffer (was a separate disk pass).
        let stopReasonMsgIds = collectStopReasonMessageIds(bufferedRecords)
        // Orphan streams (no stop_reason) bill at the max-usage record per msg.id.
        let orphanChosenIndex = selectOrphanBillingIndices(bufferedRecords, stopReasonMsgIds: stopReasonMsgIds)
        // Context-forking subagent files replay the parent's billable msg.ids;
        // exclude those copies from totals (transcript rendering still keeps them).
        let parentReplayMsgIds: Set<String> =
            (isSubagentFile && Self.isContextForkFilename(url.lastPathComponent))
            ? parentAssistantMessageIds(forSubagentFileAt: url) : []

        // Phase 3: replay the buffered records using the original accumulation logic.
        for (idx, record) in bufferedRecords.enumerated() {
            try Task.checkCancellation()

            // Subagent (sidechain) files carry the parent's sessionId on every record by
            // design, which would make the continuation parent-skip branch drop every
            // billable turn. Detect via the per-record isSidechain flag (CLI writes this
            // since Claude Code 2.1.81) with a path-based fallback for older records.
            let isSidechain = record.isSidechain == true || isSubagentFile

            if isFirstRecord {
                isFirstRecord = false
                if !isSidechain, let recSessionId = record.sessionId, recSessionId != sessionId {
                    parentSessionId = recSessionId
                }
            }
            if !isSidechain, let parentId = parentSessionId, record.sessionId == parentId {
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

                // Bill the record if (a) it has stop_reason (the normal final
                // record of a completed stream) or (b) it's an orphan — its
                // msg.id never produces a stop_reason record anywhere in the
                // file (aborted stream, truncated transcript). msg.id dedup
                // below ensures only the first orphan per msg.id is counted.
                let msgId = record.message?.id
                let isOrphan = msgId.map { !stopReasonMsgIds.contains($0) } ?? true
                let isBillable = record.message?.stopReason != nil || isOrphan
                if isBillable, let usage = record.message?.usage {
                    // Dedup by message id (see parseMetadata for context).
                    let alreadyCounted = msgId.map { seenMessageIds.contains($0) } ?? false
                    // Orphan with the same msg.id at a non-max index: skip so only
                    // the max-usage occurrence bills (parse() never `continue`s — the
                    // record must still reach the transcript array / toolResultMap).
                    let isNonChosenOrphan = isOrphan
                        && (msgId.flatMap { orphanChosenIndex[$0] }.map { $0 != idx } ?? false)
                    // Parent history replayed into a context-forking subagent file.
                    let isParentReplay = msgId.map { parentReplayMsgIds.contains($0) } ?? false
                    if !alreadyCounted && !isNonChosenOrphan && !isParentReplay {
                        if let id = msgId { seenMessageIds.insert(id) }
                        totalInputTokens += usage.inputTokens ?? 0
                        totalOutputTokens += usage.outputTokens ?? 0
                        totalCacheReadTokens += usage.cacheReadInputTokens ?? 0
                        totalCacheCreationTokens += usage.cacheCreationInputTokens ?? 0
                    }
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

        if isSubagentFile {
            // Subagent files live at .../<parentId>/subagents/<subId>.jsonl — restore the
            // parent-session linkage that the per-record skip above intentionally suppresses.
            parentSessionId = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
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
            parentSessionId: parentSessionId,
            isSubagent: isSubagentFile
        )
    }

    /// Parse a JSONL transcript that does not live under ~/.claude/projects/.
    /// Used by the Cowork rail, which reads from ~/Library/Application Support/Claude/
    /// where the path-based projectId derivation in `parse(url:sessionId:)`
    /// would yield "". Caller passes an explicit projectId.
    func parseTranscript(url: URL, sessionId: String, projectId: String) throws -> ParsedSession {
        let parsed = try parse(url: url, sessionId: sessionId)
        return ParsedSession(
            id: parsed.id,
            projectId: projectId,
            slug: parsed.slug,
            records: parsed.records,
            toolResultMap: parsed.toolResultMap,
            metadata: parsed.metadata,
            parentSessionId: parsed.parentSessionId,
            isSubagent: parsed.isSubagent
        )
    }

    /// Quick metadata extraction for sidebar listing
    func parseMetadata(url: URL, sessionId: String, pricingTable: [String: ModelPricing]) throws -> SessionSummary {
        // Single disk pass: stream-decode the file once into a buffered list of
        // lite-decoded records, then process the buffer in memory. Previously
        // we made two disk passes (one for stopReasonMsgIds, one for the main
        // loop), which doubled I/O on the startup path. The lite decoder drops
        // the heaviest field (`input` blob on tool_use blocks) so per-record
        // memory is dominated by `text`/`thinking` content: typically sub-MB
        // per file, well-bounded under ProjectScanner's concurrency cap of 8.
        guard let fileHandle = FileHandle(forReadingAtPath: url.path) else {
            throw SessionParserError.fileNotFound
        }
        defer { fileHandle.closeFile() }

        // Bug fix: use local dedup set instead of actor-level seenUUIDs
        // to avoid cross-session dedup that causes costs to drop to $0 over time
        var localSeenUUIDs = Set<String>()
        // Primary dedup key. Claude Code re-persists the same Anthropic API response
        // (same msg_xxx id) across tool-use turn boundaries: different uuids and
        // timestamps but identical usage block. Counting each copy inflated cost
        // by ~80% on tool-heavy sessions (Igor: $1616 -> $922, vs $898 actual bill).
        var localSeenMessageIds = Set<String>()

        let projectId = deriveProjectId(from: url)
        let isSubagentFile = url.deletingLastPathComponent().lastPathComponent == "subagents"

        // Phase 1: stream-decode the file once. We don't apply any record
        // filters here so that phase 2's stop-reason set is computed over the
        // exact same record set the legacy two-pass version would have seen
        // (it didn't filter either). Phase 3 applies the per-record filters.
        var bufferedRecords: [ParsedRecordRaw] = []
        var lineCount = 0
        var firstLine = ""
        for line in StreamingLineReader(fileHandle: fileHandle) {
            try Task.checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            lineCount += 1
            if lineCount == 1 { firstLine = trimmed }
            guard let lineData = trimmed.data(using: .utf8) else { continue }
            guard let raw = try? liteDecoder.decode(ParsedRecordRaw.self, from: lineData) else {
                continue
            }
            bufferedRecords.append(raw)
        }

        // Phase 2: derive the stop_reason msg.id set from the in-memory buffer
        // (used by the main loop to distinguish intermediates from orphans).
        let stopReasonMsgIds = collectStopReasonMessageIds(bufferedRecords)
        // Orphan streams (no stop_reason) bill at the max-usage record per msg.id.
        let orphanChosenIndex = selectOrphanBillingIndices(bufferedRecords, stopReasonMsgIds: stopReasonMsgIds)
        // Context-forking subagent files replay the parent's billable msg.ids;
        // exclude those copies from totals.
        let parentReplayMsgIds: Set<String> =
            (isSubagentFile && Self.isContextForkFilename(url.lastPathComponent))
            ? parentAssistantMessageIds(forSubagentFileAt: url) : []
        // Per-day accumulators (LOCAL day key). The lump token/cost totals and the
        // per-family modelBreakdown are derived from these after the loop.
        var dayAccs: [String: DayAcc] = [:]
        var lastSeenDay: String? = nil
        // Kept keyed by full model id (not family) because primaryModel selection
        // needs per-model-id granularity.
        var modelOutputTokens: [String: Int] = [:]
        var hasError = false
        var slug: String?
        var customTitle: String?
        var recordTitle: String?
        var isFirstRecord = true
        var parentSessionId: String? = nil
        var firstTimestamp = ""
        var lastTimestamp = ""
        var compactionCount = 0
        var toolCallCount = 0

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

        // LOCAL calendar day (YYYY-MM-DD) for per-day cost attribution. Local (not
        // UTC) so it matches Calendar.current.startOfDay used by the "today" filter
        // in SessionStore and AnalyticsTimeRange.
        let localDayFormatter = DateFormatter()
        localDayFormatter.dateFormat = "yyyy-MM-dd"
        localDayFormatter.locale = Locale(identifier: "en_US_POSIX")
        func localDayKey(_ ts: String) -> String? {
            guard let date = ISO8601.parse(ts) else { return nil }
            return localDayFormatter.string(from: date)
        }

        // Phase 3: replay the buffered records using the original accumulation
        // logic. Identical semantics to the previous streaming version: the
        // only difference is that we already have the full record set in
        // memory, so the orphan-detection set above can be precomputed.
        var spawnedAgentIds = Set<String>()
        for (idx, raw) in bufferedRecords.enumerated() {
            try Task.checkCancellation()
            if let ts = raw.timestamp {
                if firstTimestamp.isEmpty { firstTimestamp = ts }
                lastTimestamp = ts
                if let dk = localDayKey(ts) { lastSeenDay = dk }
            }

            let isSidechain = raw.isSidechain == true || isSubagentFile

            if isFirstRecord {
                isFirstRecord = false
                if !isSidechain, let recSessionId = raw.sessionId, recSessionId != sessionId {
                    parentSessionId = recSessionId
                }
            }
            if !isSidechain, let parentId = parentSessionId, raw.sessionId == parentId {
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
            // Session-level title (forward-compatible; nil for all current records).
            if let t = raw.title, !t.isEmpty {
                recordTitle = t
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

                // Bill the record if (a) it has stop_reason (final record of a
                // completed stream, carrying cumulative usage) or (b) it's an
                // orphan — no record with this msg.id ever has stop_reason in
                // the file (aborted streams, truncated transcripts). msg.id
                // dedup below keeps each orphan to a single occurrence.
                let orphanMsgId = raw.message?.id
                let isOrphan = orphanMsgId.map { !stopReasonMsgIds.contains($0) } ?? true
                let isBillable = raw.message?.stopReason != nil || isOrphan
                if isBillable, let usage = raw.message?.usage {
                    // Orphan with the same msg.id at a non-max index: skip so only the
                    // max-usage occurrence bills. Must run BEFORE the seen-id inserts,
                    // or the chosen record gets deduped to zero.
                    if isOrphan, let mid = orphanMsgId, let chosen = orphanChosenIndex[mid], chosen != idx { continue }
                    // Parent history replayed into a context-forking subagent file:
                    // the genuinely-new calls have ids not present in the parent.
                    if let mid = orphanMsgId, parentReplayMsgIds.contains(mid) { continue }
                    // Primary dedup: same Anthropic message id = same billable API call.
                    if let msgId = raw.message?.id {
                        if localSeenMessageIds.contains(msgId) { continue }
                        localSeenMessageIds.insert(msgId)
                    }
                    // Secondary dedup: same record uuid (legacy continuation-file case).
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

                    // Fast mode: usage.speed is per assistant message (sibling of
                    // service_tier inside the usage block), so the multiplier applies
                    // at the same granularity as this per-message cost.
                    let speed = usage.speed
                    let isFastMode = speed != nil && speed != "standard"
                    let speedMultiplier = isFastMode ? fastModeRateMultiplier : 1.0

                    // Cost per-message using each message's actual model.
                    let msgCost = estimateCostFromTokens(
                        model: raw.message?.model,
                        inputTokens: msgInput,
                        outputTokens: msgOutput,
                        cacheReadTokens: msgCacheRead,
                        cacheCreation5mTokens: msgCache5m,
                        cacheCreation1hTokens: msgCache1h,
                        table: pricingTable,
                        speedMultiplier: speedMultiplier
                    )

                    // Attribute to the LOCAL day this message landed on. lastSeenDay
                    // tracks the most recent timestamped record (updated at the top of
                    // the loop), so a billable record missing its own timestamp falls
                    // back to that day. The "1970-01-01" sentinel only applies to a file
                    // with no parseable timestamp anywhere, which keeps the derived
                    // lump == sum(contributions) invariant intact (that day never
                    // matches a real date window).
                    let dayKey = lastSeenDay ?? "1970-01-01"
                    var day = dayAccs[dayKey] ?? DayAcc()
                    day.inputTokens += msgInput
                    day.outputTokens += msgOutput
                    day.cacheReadTokens += msgCacheRead
                    day.cacheCreationTokens += msgCacheCreate
                    day.cacheCreation5mTokens += msgCache5m
                    day.cacheCreation1hTokens += msgCache1h
                    day.estimatedCost += msgCost
                    if let model = raw.message?.model {
                        let family = getModelFamily(model)
                        modelOutputTokens[model, default: 0] += msgOutput
                        var m = day.model[family] ?? ModelDayAcc()
                        m.inputTokens += msgInput
                        m.outputTokens += msgOutput
                        m.cacheReadTokens += msgCacheRead
                        m.estimatedCost += msgCost
                        m.turnCount += 1
                        day.model[family] = m
                    }
                    dayAccs[dayKey] = day

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
                let messageText = raw.message?.content?.textContent ?? ""
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

            if let childId = raw.toolUseResult?.childAgentId, !childId.isEmpty {
                spawnedAgentIds.insert(ObservabilityAnalyzer.normalizeAgentId(childId))
            }

            if let ts = raw.timestamp { recordTimestamps.append(ts) }
        }

        let title = deriveTitle(title: recordTitle, customTitle: customTitle, slug: slug, firstLine: firstLine, sessionId: sessionId)
        let primaryModel = modelOutputTokens.max(by: { $0.value < $1.value })?.key

        // Derive the lump totals, the per-family modelBreakdown, and the immutable
        // dailyContributions from the day buckets in a single pass. Everything billed
        // flows through dayAccs, so these three views are guaranteed to reconcile.
        var totalInputTokens = 0
        var totalOutputTokens = 0
        var totalCacheReadTokens = 0
        var totalCacheCreationTokens = 0
        var totalCacheCreation5mTokens = 0
        var totalCacheCreation1hTokens = 0
        var perMessageCost = 0.0
        var familyInput: [String: Int] = [:]
        var familyOutput: [String: Int] = [:]
        var familyCacheRead: [String: Int] = [:]
        var familyCost: [String: Double] = [:]
        var familyTurns: [String: Int] = [:]

        let dailyContributions: [DailyContribution] = dayAccs.keys.sorted().map { dayKey in
            let acc = dayAccs[dayKey]!
            totalInputTokens += acc.inputTokens
            totalOutputTokens += acc.outputTokens
            totalCacheReadTokens += acc.cacheReadTokens
            totalCacheCreationTokens += acc.cacheCreationTokens
            totalCacheCreation5mTokens += acc.cacheCreation5mTokens
            totalCacheCreation1hTokens += acc.cacheCreation1hTokens
            perMessageCost += acc.estimatedCost
            let models = acc.model.keys.sorted().map { family -> ModelDayCost in
                let m = acc.model[family]!
                familyInput[family, default: 0] += m.inputTokens
                familyOutput[family, default: 0] += m.outputTokens
                familyCacheRead[family, default: 0] += m.cacheReadTokens
                familyCost[family, default: 0] += m.estimatedCost
                familyTurns[family, default: 0] += m.turnCount
                return ModelDayCost(
                    model: family,
                    inputTokens: m.inputTokens,
                    outputTokens: m.outputTokens,
                    cacheReadTokens: m.cacheReadTokens,
                    estimatedCost: m.estimatedCost,
                    turnCount: m.turnCount
                )
            }
            return DailyContribution(
                date: dayKey,
                inputTokens: acc.inputTokens,
                outputTokens: acc.outputTokens,
                cacheReadTokens: acc.cacheReadTokens,
                cacheCreationTokens: acc.cacheCreationTokens,
                cacheCreation5mTokens: acc.cacheCreation5mTokens,
                cacheCreation1hTokens: acc.cacheCreation1hTokens,
                estimatedCost: acc.estimatedCost,
                modelBreakdown: models
            )
        }

        let modelBreakdown = familyTurns.keys.map { family in
            ModelTokenBreakdown(
                model: family,
                inputTokens: familyInput[family, default: 0],
                outputTokens: familyOutput[family, default: 0],
                cacheReadTokens: familyCacheRead[family, default: 0],
                estimatedCost: familyCost[family, default: 0],
                turnCount: familyTurns[family, default: 0]
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
            observability: observability,
            isSubagent: isSubagentFile,
            dailyContributions: dailyContributions,
            agentId: isSubagentFile ? ObservabilityAnalyzer.normalizeAgentId(sessionId) : nil,
            spawnedAgentIds: Array(spawnedAgentIds)
        )
    }

    private func deriveProjectId(from url: URL) -> String {
        let components = url.pathComponents
        if let idx = components.lastIndex(of: "projects"), idx + 1 < components.count {
            return components[idx + 1]
        }
        return "unknown"
    }

    private func deriveTitle(title: String?, customTitle: String?, slug: String?, firstLine: String, sessionId: String) -> String {
        // A session-level `title` (if the CLI ever stamps one) wins outright.
        // Then /rename (writes a custom-title record) takes precedence over the
        // slug, since the slug field is never updated when the user renames a session.
        if let title { return title }
        if let customTitle { return customTitle }
        if let slug { return slug }

        if let data = firstLine.data(using: .utf8),
           let raw = try? fullDecoder.decode(ParsedRecordRaw.self, from: data),
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

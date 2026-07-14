import Foundation
import CryptoKit
import OrderedCollections

/// Extracts per-file change history (with diffs) for the session-detail Files tab.
///
/// Deliberately independent of SessionParser: the diff payloads live in the
/// `toolUseResult` objects that ParsedRecordRaw decodes only shallowly, and
/// extending that type would touch the perf-guarded lite scan and the billing
/// path (see the parserVersion contract). Instead this service re-streams the
/// JSONL with its own lenient decoders when the Files tab activates, the same
/// way the secrets linter re-reads raw session lines.
///
/// Every successful Edit/Write result carries a CLI-computed `structuredPatch`
/// (JS diff hunks), so no diff algorithm runs here; hunks render verbatim.
actor FileChangesService {

    // MARK: - Locator

    /// Single source of truth for "which file backs this session's Files tab
    /// and under what key". Both SessionStore.loadFileChanges and
    /// SessionFilesView derive url/key through this, so the view's stale-guard
    /// key can never diverge from the store's (a divergence would leave the
    /// tab loading forever). For subagent transcripts `session.id` is the
    /// subagent file stem and `parentSessionId` holds the real session id.
    static func fileChangesLocator(for session: ParsedSession, claudeDir: URL) -> (url: URL, key: String) {
        let projectDir = claudeDir
            .appendingPathComponent("projects")
            .appendingPathComponent(session.projectId)
        if session.isSubagent, let parentId = session.parentSessionId {
            let url = projectDir
                .appendingPathComponent(parentId)
                .appendingPathComponent("subagents")
                .appendingPathComponent("\(session.id).jsonl")
            return (url, "\(parentId)/subagents/\(session.id)")
        }
        return (projectDir.appendingPathComponent("\(session.id).jsonl"), session.id)
    }

    // MARK: - Cache

    private var cache = OrderedDictionary<String, (fingerprint: String, changeSet: FileChangeSet)>()
    private static let cacheCapacity = 8

    // MARK: - Public API

    /// Extract (or return cached) file changes for the transcript at
    /// `mainFileURL`, merging `subagents/*.jsonl` siblings when the main file
    /// is a top-level session transcript.
    func loadChangeSet(mainFileURL: URL, sessionKey: String) throws -> FileChangeSet {
        let isSubagentFile = mainFileURL.deletingLastPathComponent().lastPathComponent == "subagents"
        let subagentURLs = isSubagentFile ? [] : discoverSubagentFiles(mainFileURL: mainFileURL)

        let fingerprint = Self.fingerprint(for: [mainFileURL] + subagentURLs)
        if let cached = cache[sessionKey], cached.fingerprint == fingerprint {
            cache.removeValue(forKey: sessionKey)
            cache[sessionKey] = cached
            return cached.changeSet
        }

        let parent = try extract(url: mainFileURL)
        var subagents: [(stem: String, extraction: Extraction)] = []
        for url in subagentURLs {
            let stem = url.deletingPathExtension().lastPathComponent
            subagents.append((stem, try extract(url: url)))
        }

        let changeSet = Self.merge(sessionKey: sessionKey, parent: parent, subagents: subagents)

        cache.removeValue(forKey: sessionKey)
        cache[sessionKey] = (fingerprint, changeSet)
        while cache.count > Self.cacheCapacity {
            cache.removeFirst()
        }
        return changeSet
    }

    /// Compare each file's reconstructed final content hash against the bytes
    /// on disk right now. Never cached: a cache hit on the change set must
    /// still re-check disk.
    func diskStates(for changeSet: FileChangeSet) -> [String: FileDiskState] {
        var states: [String: FileDiskState] = [:]
        for file in changeSet.files {
            guard let expected = file.finalContentSHA256 else {
                states[file.path] = .unknown
                continue
            }
            guard FileManager.default.fileExists(atPath: file.path) else {
                states[file.path] = .missing
                continue
            }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: file.path)) else {
                states[file.path] = .unknown
                continue
            }
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            states[file.path] = (actual == expected) ? .clean : .modified
        }
        return states
    }

    // MARK: - Patch text

    /// Unified-diff text for one edit event. Creates diff against /dev/null.
    static func unifiedPatchText(event: FileEditEvent, displayPath: String) -> String {
        let headerPath = displayPath.hasPrefix("/") ? String(displayPath.dropFirst()) : displayPath
        var out = event.kind == .writeCreate ? "--- /dev/null\n" : "--- a/\(headerPath)\n"
        out += "+++ b/\(headerPath)\n"
        for hunk in event.hunks {
            out += "@@ -\(hunk.oldStart),\(hunk.oldLines) +\(hunk.newStart),\(hunk.newLines) @@\n"
            for line in hunk.lines {
                out += line + "\n"
            }
        }
        return out
    }

    /// All of a file's edits as one patch: per-event sections concatenated
    /// chronologically. Apply sequentially with patch(1) from the pre-session
    /// file; each section's line numbers target the intermediate state.
    /// Known v1 limit: no "\ No newline at end of file" markers (the CLI's
    /// structuredPatch does not carry that flag).
    static func unifiedPatchText(file: ChangedFile) -> String {
        file.events.map { unifiedPatchText(event: $0, displayPath: file.displayPath) }.joined()
    }

    // MARK: - Final content reconstruction

    /// Replicates what the CLI's Edit tool did: replace the first occurrence of
    /// oldString (or every occurrence when replaceAll) in the pre-edit content.
    /// nil when the replacement cannot be applied.
    static func finalContent(original: String, oldString: String, newString: String, replaceAll: Bool) -> String? {
        guard !oldString.isEmpty else { return nil }
        if replaceAll {
            guard original.contains(oldString) else { return nil }
            return original.replacingOccurrences(of: oldString, with: newString)
        }
        guard let range = original.range(of: oldString) else { return nil }
        return original.replacingCharacters(in: range, with: newString)
    }

    static func sha256Hex(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Discovery / fingerprint

    private func discoverSubagentFiles(mainFileURL: URL) -> [URL] {
        let subagentsDir = mainFileURL.deletingPathExtension().appendingPathComponent("subagents")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: subagentsDir.path) else {
            return []
        }
        return names.filter { $0.hasSuffix(".jsonl") }.sorted().map {
            subagentsDir.appendingPathComponent($0)
        }
    }

    private static func fingerprint(for urls: [URL]) -> String {
        urls.map { url in
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int) ?? -1
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            return "\(url.lastPathComponent):\(size):\(mtime)"
        }.joined(separator: ";")
    }

    // MARK: - Extraction

    /// Everything one transcript contributes before the merge.
    private struct Extraction {
        var events: [WorkingEvent] = []
        /// Every tool_use block id -> assistant record uuid (for spawn anchoring).
        var toolUseIdToUuid: [String: String] = [:]
        /// tool_use id -> input.subagent_type (Agent/Task calls only).
        var toolUseIdToSubagentType: [String: String] = [:]
        /// Normalized child agent id -> the tool_use id of the spawning call.
        var spawnEdges: [String: String] = [:]
    }

    private struct WorkingEvent {
        let toolUseId: String
        let kind: FileEditKind
        let path: String
        let cwd: String?
        let order: Int
        let recordUuid: String?
        let timestamp: String?
        let hunks: [PatchHunk]
        let additions: Int
        let deletions: Int
        let replaceAll: Bool
        let userModified: Bool
        let isFallback: Bool
        let finalSHA: String?
    }

    private struct PendingToolUse {
        let toolName: String
        let recordUuid: String?
        let timestamp: String?
        let cwd: String?
        let inputFilePath: String?
        let notebookNewSource: String?
        let notebookEditMode: String?
    }

    private static let editToolNames: Set<String> = ["Edit", "Write", "NotebookEdit", "MultiEdit"]

    /// Truncation guard: a pathological Write should not balloon results.
    private static let maxHunkLines = 2000

    private func extract(url: URL) throws -> Extraction {
        guard let fileHandle = FileHandle(forReadingAtPath: url.path) else {
            return Extraction()
        }
        defer { fileHandle.closeFile() }

        let decoder = JSONDecoder()
        var extraction = Extraction()
        var pending: [String: PendingToolUse] = [:]
        var order = 0

        for line in StreamingLineReader(fileHandle: fileHandle) {
            try Task.checkCancellation()
            // Cheap gate: assistant tool_use blocks carry "type":"tool_use" and
            // every result line carries an embedded tool_result "tool_use_id"
            // ("toolUseResult" itself is camelCase and never matches).
            guard line.contains("tool_use") else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
                  let record = try? decoder.decode(FCLine.self, from: data) else { continue }

            if record.type == "assistant" {
                guard case .blocks(let blocks)? = record.message?.content else { continue }
                for block in blocks where block.type == "tool_use" {
                    guard let toolId = block.id else { continue }
                    extraction.toolUseIdToUuid[toolId] = record.uuid ?? extraction.toolUseIdToUuid[toolId]
                    if let subagentType = block.input?.subagentType {
                        extraction.toolUseIdToSubagentType[toolId] = subagentType
                    }
                    guard let name = block.name, Self.editToolNames.contains(name) else { continue }
                    pending[toolId] = PendingToolUse(
                        toolName: name,
                        recordUuid: record.uuid,
                        timestamp: record.timestamp,
                        cwd: record.cwd,
                        inputFilePath: block.input?.filePath ?? block.input?.notebookPath,
                        notebookNewSource: block.input?.newSource,
                        notebookEditMode: block.input?.editMode
                    )
                }
                continue
            }

            // Result-carrying line (user record, or legacy top-level tool_result).
            let resultObject: FCToolUseResult?
            if case .object(let obj)? = record.toolUseResult {
                resultObject = obj
            } else {
                resultObject = nil
            }

            // Embedded tool_result blocks are the modern join key; the
            // top-level object's tool_use_id is a legacy fallback.
            var joins: [(toolUseId: String, isError: Bool)] = []
            if case .blocks(let blocks)? = record.message?.content {
                for block in blocks where block.type == "tool_result" {
                    if let joinId = block.toolUseId {
                        joins.append((joinId, block.isError ?? false))
                    }
                }
            }
            if joins.isEmpty, let legacyId = resultObject?.toolUseId {
                joins.append((legacyId, resultObject?.isError ?? false))
            }

            var resultConsumed = false
            for join in joins {
                // Spawn edge: the Agent/Task result names the child it created.
                if let agentId = resultObject?.agentId, !agentId.isEmpty, !resultConsumed {
                    let normalized = ObservabilityAnalyzer.normalizeAgentId(agentId)
                    if extraction.spawnEdges[normalized] == nil {
                        extraction.spawnEdges[normalized] = join.toolUseId
                    }
                }

                guard let pendingCall = pending.removeValue(forKey: join.toolUseId) else { continue }
                if join.isError { continue }
                let payload: FCToolUseResult?
                if !resultConsumed, let object = resultObject {
                    payload = object
                    resultConsumed = true
                } else {
                    payload = nil
                }
                // Edit/Write success always writes an object payload; a bare
                // string here is the rejected/failed shape. NotebookEdit
                // results are legitimately plain strings, handled by fallback.
                if payload == nil && pendingCall.toolName != "NotebookEdit" { continue }
                if let event = Self.buildEvent(
                    toolUseId: join.toolUseId,
                    pending: pendingCall,
                    result: payload,
                    order: order
                ) {
                    extraction.events.append(event)
                    order += 1
                }
            }
        }
        return extraction
    }

    /// nil = no visible change to record (rejected edits arrive as is_error or
    /// as a bare-string toolUseResult and are filtered before this point; here
    /// nil only means the payload had no usable path).
    private static func buildEvent(
        toolUseId: String,
        pending: PendingToolUse,
        result: FCToolUseResult?,
        order: Int
    ) -> WorkingEvent? {
        guard let path = result?.filePath ?? pending.inputFilePath, !path.isEmpty else { return nil }

        let kind: FileEditKind
        switch pending.toolName {
        case "Write":
            let isCreate = result?.type == "create"
                || (result?.type == nil && (result?.originalFile ?? "").isEmpty)
            kind = isCreate ? .writeCreate : .writeUpdate
        case "NotebookEdit":
            kind = .notebookEdit
        default:
            kind = .edit
        }

        var hunks = (result?.structuredPatch ?? []).map { raw in
            PatchHunk(
                oldStart: raw.oldStart ?? 0,
                oldLines: raw.oldLines ?? 0,
                newStart: raw.newStart ?? 0,
                newLines: raw.newLines ?? 0,
                lines: raw.lines ?? []
            )
        }
        var isFallback = false

        if hunks.isEmpty {
            // Patch missing: synthesize an all-added hunk where the full new
            // content is known (Write create, NotebookEdit new_source).
            let synthSource: String?
            switch kind {
            case .writeCreate:
                synthSource = result?.content
            case .notebookEdit:
                synthSource = (pending.notebookEditMode == "delete") ? nil : pending.notebookNewSource
                isFallback = true
            default:
                synthSource = nil
            }
            if let source = synthSource, !source.isEmpty {
                let lines = source.components(separatedBy: "\n").map { "+" + $0 }
                hunks = [PatchHunk(oldStart: 0, oldLines: 0, newStart: 1, newLines: lines.count, lines: lines)]
                if kind == .writeCreate { isFallback = true }
            }
        }

        hunks = hunks.map { truncated($0) }
        let additions = hunks.reduce(0) { $0 + $1.lines.filter { $0.hasPrefix("+") }.count }
        let deletions = hunks.reduce(0) { $0 + $1.lines.filter { $0.hasPrefix("-") }.count }

        let finalSHA: String?
        switch kind {
        case .writeCreate, .writeUpdate:
            finalSHA = result?.content.map { sha256Hex($0) }
        case .edit:
            if let original = result?.originalFile,
               let oldString = result?.oldString,
               let newString = result?.newString,
               let final = finalContent(
                   original: original,
                   oldString: oldString,
                   newString: newString,
                   replaceAll: result?.replaceAll ?? false
               ) {
                finalSHA = sha256Hex(final)
            } else {
                finalSHA = nil
            }
        case .notebookEdit:
            finalSHA = nil
        }

        return WorkingEvent(
            toolUseId: toolUseId,
            kind: kind,
            path: path,
            cwd: pending.cwd,
            order: order,
            recordUuid: pending.recordUuid,
            timestamp: pending.timestamp,
            hunks: hunks,
            additions: additions,
            deletions: deletions,
            replaceAll: result?.replaceAll ?? false,
            userModified: result?.userModified ?? false,
            isFallback: isFallback,
            finalSHA: finalSHA
        )
    }

    private static func truncated(_ hunk: PatchHunk) -> PatchHunk {
        guard hunk.lines.count > maxHunkLines else { return hunk }
        var lines = Array(hunk.lines.prefix(maxHunkLines))
        lines.append("\\ truncated (\(hunk.lines.count - maxHunkLines) more lines)")
        return PatchHunk(
            oldStart: hunk.oldStart, oldLines: hunk.oldLines,
            newStart: hunk.newStart, newLines: hunk.newLines,
            lines: lines
        )
    }

    // MARK: - Merge

    private static func merge(
        sessionKey: String,
        parent: Extraction,
        subagents: [(stem: String, extraction: Extraction)]
    ) -> FileChangeSet {
        struct Attributed {
            let event: WorkingEvent
            let agentLabel: String?
            let jumpTargetUuid: String?
            let fromParent: Bool
        }

        var seenIds = Set<String>()
        var attributed: [Attributed] = []

        // Parent first: it wins the dedup against context-fork replays
        // (agent-acompact-* / agent-aside_question-* files copy the parent's
        // tool_use records verbatim, same block ids).
        for event in parent.events {
            guard seenIds.insert(event.toolUseId).inserted else { continue }
            attributed.append(Attributed(
                event: event,
                agentLabel: nil,
                jumpTargetUuid: event.recordUuid,
                fromParent: true
            ))
        }

        for (stem, extraction) in subagents {
            let normalizedId = ObservabilityAnalyzer.normalizeAgentId(stem)
            let spawningToolUseId = parent.spawnEdges[normalizedId]
            let jumpTarget = spawningToolUseId.flatMap { parent.toolUseIdToUuid[$0] }
            let label = spawningToolUseId.flatMap { parent.toolUseIdToSubagentType[$0] }
                ?? String(normalizedId.prefix(8))
            for event in extraction.events {
                guard seenIds.insert(event.toolUseId).inserted else { continue }
                attributed.append(Attributed(
                    event: event,
                    agentLabel: label,
                    jumpTargetUuid: jumpTarget,
                    fromParent: false
                ))
            }
        }

        // Chronological: ISO-8601 Z-suffixed timestamps compare lexicographically;
        // nil timestamps last; ties parent-first then original line order.
        func earlier(_ a: Attributed, _ b: Attributed) -> Bool {
            switch (a.event.timestamp, b.event.timestamp) {
            case let (ta?, tb?) where ta != tb: return ta < tb
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                if a.fromParent != b.fromParent { return a.fromParent }
                return a.event.order < b.event.order
            }
        }

        // Grouping order does not matter: the final files.sort below decides it.
        var byPath: [String: [Attributed]] = [:]
        for item in attributed {
            byPath[item.event.path, default: []].append(item)
        }

        var files: [ChangedFile] = []
        for (path, items) in byPath {
            let sorted = items.sorted(by: earlier)
            let events = sorted.map { item in
                FileEditEvent(
                    id: item.event.toolUseId,
                    kind: item.event.kind,
                    recordUuid: item.event.recordUuid,
                    jumpTargetUuid: item.jumpTargetUuid,
                    agentLabel: item.agentLabel,
                    timestamp: item.event.timestamp,
                    hunks: item.event.hunks,
                    additions: item.event.additions,
                    deletions: item.event.deletions,
                    replaceAll: item.event.replaceAll,
                    userModified: item.event.userModified,
                    isFallbackRendering: item.event.isFallback
                )
            }
            let cwd = sorted.first?.event.cwd
            let displayPath: String
            if let cwd, !cwd.isEmpty, path.hasPrefix(cwd + "/") {
                displayPath = String(path.dropFirst(cwd.count + 1))
            } else {
                displayPath = path
            }
            files.append(ChangedFile(
                path: path,
                displayPath: displayPath,
                isNewFile: events.first?.kind == .writeCreate,
                events: events,
                additions: events.reduce(0) { $0 + $1.additions },
                deletions: events.reduce(0) { $0 + $1.deletions },
                finalContentSHA256: sorted.last?.event.finalSHA,
                lastTimestamp: events.compactMap(\.timestamp).last
            ))
        }

        files.sort { a, b in
            switch (a.events.first?.timestamp, b.events.first?.timestamp) {
            case let (ta?, tb?) where ta != tb: return ta < tb
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.path < b.path
            }
        }

        return FileChangeSet(
            sessionKey: sessionKey,
            files: files,
            totalAdditions: files.reduce(0) { $0 + $1.additions },
            totalDeletions: files.reduce(0) { $0 + $1.deletions },
            totalEvents: files.reduce(0) { $0 + $1.events.count }
        )
    }
}

// MARK: - Lenient decode types
// Private to this feature; never touch DecodeMode or ParsedRecordRaw. Every
// field decodes with try? so a shape drift in one key can never drop a line.

private struct FCLine: Decodable {
    let type: String?
    let uuid: String?
    let timestamp: String?
    let cwd: String?
    let message: FCMessage?
    let toolUseResult: FCToolUseResultField?

    enum CodingKeys: String, CodingKey {
        case type, uuid, timestamp, cwd, message, toolUseResult
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        uuid = try? c.decodeIfPresent(String.self, forKey: .uuid)
        timestamp = try? c.decodeIfPresent(String.self, forKey: .timestamp)
        cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
        message = try? c.decodeIfPresent(FCMessage.self, forKey: .message)
        toolUseResult = try? c.decodeIfPresent(FCToolUseResultField.self, forKey: .toolUseResult)
    }
}

private struct FCMessage: Decodable {
    let content: FCContent?

    enum CodingKeys: String, CodingKey { case content }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = try? c.decodeIfPresent(FCContent.self, forKey: .content)
    }
}

private enum FCContent: Decodable {
    case blocks([FCBlock])
    case other

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let blocks = try? c.decode([FCBlock].self) {
            self = .blocks(blocks)
        } else {
            self = .other
        }
    }
}

private struct FCBlock: Decodable {
    let type: String?
    let id: String?
    let name: String?
    let toolUseId: String?
    let isError: Bool?
    let input: FCToolInput?

    enum CodingKeys: String, CodingKey {
        case type, id, name, input
        case toolUseId = "tool_use_id"
        case isError = "is_error"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        id = try? c.decodeIfPresent(String.self, forKey: .id)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        toolUseId = try? c.decodeIfPresent(String.self, forKey: .toolUseId)
        isError = try? c.decodeIfPresent(Bool.self, forKey: .isError)
        input = try? c.decodeIfPresent(FCToolInput.self, forKey: .input)
    }
}

private struct FCToolInput: Decodable {
    let filePath: String?
    let notebookPath: String?
    let editMode: String?
    let newSource: String?
    let subagentType: String?

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case notebookPath = "notebook_path"
        case editMode = "edit_mode"
        case newSource = "new_source"
        case subagentType = "subagent_type"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filePath = try? c.decodeIfPresent(String.self, forKey: .filePath)
        notebookPath = try? c.decodeIfPresent(String.self, forKey: .notebookPath)
        editMode = try? c.decodeIfPresent(String.self, forKey: .editMode)
        newSource = try? c.decodeIfPresent(String.self, forKey: .newSource)
        subagentType = try? c.decodeIfPresent(String.self, forKey: .subagentType)
    }
}

/// `toolUseResult` is an object for successful tool calls but a bare string
/// for rejected/failed ones; the wrapper keeps both shapes from throwing.
private enum FCToolUseResultField: Decodable {
    case object(FCToolUseResult)
    case other

    init(from decoder: Decoder) throws {
        if let obj = try? FCToolUseResult(from: decoder) {
            self = .object(obj)
        } else {
            self = .other
        }
    }
}

private struct FCToolUseResult: Decodable {
    let toolUseId: String?
    let isError: Bool?
    let filePath: String?
    let oldString: String?
    let newString: String?
    let replaceAll: Bool?
    let content: String?
    let originalFile: String?
    let structuredPatch: [FCHunk]?
    let userModified: Bool?
    let type: String?
    let agentId: String?

    enum CodingKeys: String, CodingKey {
        case filePath, oldString, newString, replaceAll, content, originalFile
        case structuredPatch, userModified, type, agentId
        case toolUseId = "tool_use_id"
        case isError = "is_error"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toolUseId = try? c.decodeIfPresent(String.self, forKey: .toolUseId)
        isError = try? c.decodeIfPresent(Bool.self, forKey: .isError)
        filePath = try? c.decodeIfPresent(String.self, forKey: .filePath)
        oldString = try? c.decodeIfPresent(String.self, forKey: .oldString)
        newString = try? c.decodeIfPresent(String.self, forKey: .newString)
        replaceAll = try? c.decodeIfPresent(Bool.self, forKey: .replaceAll)
        content = try? c.decodeIfPresent(String.self, forKey: .content)
        originalFile = try? c.decodeIfPresent(String.self, forKey: .originalFile)
        structuredPatch = try? c.decodeIfPresent([FCHunk].self, forKey: .structuredPatch)
        userModified = try? c.decodeIfPresent(Bool.self, forKey: .userModified)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        agentId = try? c.decodeIfPresent(String.self, forKey: .agentId)
    }
}

private struct FCHunk: Decodable {
    let oldStart: Int?
    let oldLines: Int?
    let newStart: Int?
    let newLines: Int?
    let lines: [String]?
}

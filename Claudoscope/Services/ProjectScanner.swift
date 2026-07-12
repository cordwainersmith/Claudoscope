import Foundation

/// Scans ~/.claude/projects/ directories to discover projects and session files.
/// Port of server/services/project-scanner.ts
struct ProjectScanner {
    let claudeDir: URL
    let parser: SessionParser
    let pricingTable: [String: ModelPricing]

    /// Maximum number of files parsed concurrently to avoid CPU saturation.
    /// Heavy Claude Code users can accumulate thousands of session files;
    /// unbounded concurrency pegs the CPU and starves the UI run loop.
    private static let maxConcurrentParses = 8

    /// (projectDir, sessionId) pair present on disk. `reconcile` returns the
    /// full set so SessionStore can purge in-memory entries that have neither
    /// a file nor a cache row backing them.
    struct LiveEntryKey: Hashable, Sendable {
        let projectDir: String
        let sessionId: String
    }

    /// One applied batch of reconcile results, delivered on MainActor.
    struct ReconcileDelta: Sendable {
        let upserts: [(projectDir: String, summary: SessionSummary)]
        let deletions: [(projectDir: String, sessionId: String)]
    }

    private struct ScanEntry: Sendable {
        let dirName: String
        let url: URL
        let sessionId: String
        let size: Int64
        let mtime: Double
    }

    private enum ReconcileParseResult: Sendable {
        case parsed(projectDir: String, summary: SessionSummary, record: SessionSummaryRecord)
        case vanished(path: String)
        case failed
    }

    /// Newest-activity-first session ordering. Shared with SessionStore's
    /// cache hydration so hydrated sidebar lists match freshly scanned ones.
    static func sessionOrder(_ a: SessionSummary, _ b: SessionSummary) -> Bool {
        if a.lastTimestamp.isEmpty && b.lastTimestamp.isEmpty { return false }
        if a.lastTimestamp.isEmpty { return false }
        if b.lastTimestamp.isEmpty { return true }
        return a.lastTimestamp > b.lastTimestamp
    }

    /// Derive (projectDir, sessionId) from an absolute session-file path, the
    /// same way the live enumeration and SessionStore.handleFileChange do.
    /// Used for cache rows whose backing file no longer exists.
    static func projectDirAndSessionId(fromFilePath path: String) -> (projectDir: String, sessionId: String)? {
        let url = URL(fileURLWithPath: path)
        let components = url.pathComponents
        guard let idx = components.lastIndex(of: "projects"), idx + 1 < components.count else {
            return nil
        }
        return (components[idx + 1], url.deletingPathExtension().lastPathComponent)
    }

    /// Enumerate every session file (top-level and `<session>/subagents/`)
    /// with size+mtime from a single attributes call per file, sorted
    /// newest-mtime-first so the UI populates with recent sessions quickly
    /// while older ones load in the background.
    private func enumerateEntries() -> (entries: [ScanEntry], projectDirs: Set<String>) {
        let projectsDir = claudeDir.appendingPathComponent("projects")
        let fm = FileManager.default
        guard let dirNames = try? fm.contentsOfDirectory(atPath: projectsDir.path) else {
            return ([], [])
        }

        let projectDirs = dirNames.filter { name in
            var isDir: ObjCBool = false
            let fullPath = projectsDir.appendingPathComponent(name).path
            return fm.fileExists(atPath: fullPath, isDirectory: &isDir) && isDir.boolValue
        }

        var entries: [ScanEntry] = []
        func append(dirName: String, url: URL, sessionId: String) {
            let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
            let mtime = ((attrs[.modificationDate] as? Date) ?? .distantPast).timeIntervalSince1970
            let size = (attrs[.size] as? Int64) ?? 0
            entries.append(ScanEntry(dirName: dirName, url: url, sessionId: sessionId, size: size, mtime: mtime))
        }

        for dirName in projectDirs {
            let dirURL = projectsDir.appendingPathComponent(dirName)
            guard let topFiles = try? fm.contentsOfDirectory(atPath: dirURL.path) else {
                continue
            }
            for name in topFiles {
                if name.hasSuffix(".jsonl") {
                    let sid = String(name.dropLast(6))
                    append(dirName: dirName, url: dirURL.appendingPathComponent(name), sessionId: sid)
                }
                // Check for subagent files inside session subdirectories
                let subagentsDir = dirURL.appendingPathComponent(name).appendingPathComponent("subagents")
                if let subFiles = try? fm.contentsOfDirectory(atPath: subagentsDir.path) {
                    for subFile in subFiles where subFile.hasSuffix(".jsonl") {
                        let subId = String(subFile.dropLast(6))
                        append(dirName: dirName, url: subagentsDir.appendingPathComponent(subFile), sessionId: subId)
                    }
                }
            }
        }

        entries.sort { $0.mtime > $1.mtime }
        return (entries, Set(projectDirs))
    }

    /// Cache fingerprint for a file, computed from the enumeration's stat
    /// snapshot (never re-stat after parsing: a mid-parse append then stores a
    /// stale identity that self-heals on the next pass). Context-fork subagent
    /// files additionally fingerprint their parent transcript, because their
    /// parse output depends on it (replayed msg-id stripping). Parent absent
    /// on disk = nil fields, matching a stored NULL row via Swift ==.
    private func identityFor(
        _ entry: ScanEntry,
        statByPath: [String: (size: Int64, mtime: Double)]
    ) -> SessionSummaryStore.FileIdentity {
        var parentSize: Int64?
        var parentMtime: Double?
        if SessionParser.isContextForkSubagentFile(entry.url) {
            let parentPath = SessionParser.parentTranscriptURL(forSubagentFile: entry.url).path
            if let stat = statByPath[parentPath] {
                parentSize = stat.size
                parentMtime = stat.mtime
            }
        }
        return SessionSummaryStore.FileIdentity(
            size: entry.size, mtime: entry.mtime, parentSize: parentSize, parentMtime: parentMtime
        )
    }

    /// Scan all projects and collect session metadata.
    /// The optional `onProgress` callback fires on MainActor with (processed, total) counts.
    func scan(onProgress: (@Sendable @MainActor (Int, Int) -> Void)? = nil) async -> (projects: [Project], sessionsByProject: [String: [SessionSummary]]) {

        let projectsDir = claudeDir.appendingPathComponent("projects")
        var projects: [Project] = []
        var sessionsByProject: [String: [SessionSummary]] = [:]

        let (allEntries, projectDirSet) = enumerateEntries()

        // Parse with bounded concurrency to avoid CPU saturation
        var resultsByProject: [String: [SessionSummary]] = [:]
        let totalEntries = allEntries.count
        var processed = 0

        // Report total count immediately
        await onProgress?(0, totalEntries)

        await withTaskGroup(of: (String, SessionSummary)?.self) { group in
            var inflight = 0

            for entry in allEntries {
                if Task.isCancelled { break }
                if inflight >= Self.maxConcurrentParses {
                    if let result = await group.next() {
                        if let (dirName, summary) = result {
                            resultsByProject[dirName, default: []].append(summary)
                        }
                        processed += 1
                        // Report progress every 50 files to avoid UI churn
                        if processed % 50 == 0 {
                            await onProgress?(processed, totalEntries)
                        }
                    }
                    inflight -= 1
                }

                let capturedEntry = entry
                group.addTask {
                    do {
                        let summary = try await parser.parseMetadata(
                            url: capturedEntry.url,
                            sessionId: capturedEntry.sessionId,
                            pricingTable: pricingTable
                        )
                        return (capturedEntry.dirName, summary)
                    } catch {
                        NSLog("[Claudoscope] Scanner: failed to parse %@: %@",
                              capturedEntry.url.path, error.localizedDescription)
                        return nil
                    }
                }
                inflight += 1
            }

            for await result in group {
                if let (dirName, summary) = result {
                    resultsByProject[dirName, default: []].append(summary)
                }
                processed += 1
                if processed % 50 == 0 {
                    await onProgress?(processed, totalEntries)
                }
            }
        }

        await onProgress?(totalEntries, totalEntries)

        for dirName in projectDirSet {
            var sessions = resultsByProject[dirName] ?? []
            if sessions.isEmpty { continue }

            sessions.sort(by: Self.sessionOrder)

            let project = Project(
                id: dirName,
                name: decodeProjectName(dirName),
                path: projectsDir.appendingPathComponent(dirName).path,
                sessionCount: sessions.count
            )

            projects.append(project)
            sessionsByProject[dirName] = sessions
        }

        projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return (projects, sessionsByProject)
    }

    /// Diff the filesystem against the summary cache and re-parse only files
    /// whose fingerprint changed. Cache rows without a backing file are
    /// deleted. Results stream to `applyDelta` in batches aligned with the
    /// progress cadence; `onProgress` counts CHANGED files only, so a warm
    /// no-change pass reports (0, 0). Returns every (projectDir, sessionId)
    /// seen on disk so the caller can purge in-memory ghosts.
    ///
    /// `store == nil` degrades to a full parse through the same code path
    /// (every file counts as changed, no cache writes) — today's behavior.
    func reconcile(
        store: SessionSummaryStore?,
        onProgress: (@Sendable @MainActor (Int, Int) -> Void)? = nil,
        applyDelta: (@Sendable @MainActor (ReconcileDelta) -> Void)? = nil
    ) async -> Set<LiveEntryKey> {
        let (entries, _) = enumerateEntries()

        var liveKeys = Set<LiveEntryKey>()
        var statByPath: [String: (size: Int64, mtime: Double)] = [:]
        statByPath.reserveCapacity(entries.count)
        for entry in entries {
            liveKeys.insert(LiveEntryKey(projectDir: entry.dirName, sessionId: entry.sessionId))
            statByPath[entry.url.path] = (entry.size, entry.mtime)
        }

        var dbIdentities: [String: SessionSummaryStore.FileIdentity] = [:]
        if let store {
            do {
                dbIdentities = try await store.fetchIdentities()
            } catch {
                NSLog("[Claudoscope] Reconcile: identity fetch failed (%@), falling back to full reparse",
                      error.localizedDescription)
            }
        }

        // Bucket: exact identity match = unchanged, skip. Anything else parses.
        // Entries keep their newest-first order so fresh sessions land first.
        var changed: [(entry: ScanEntry, identity: SessionSummaryStore.FileIdentity)] = []
        for entry in entries {
            let identity = identityFor(entry, statByPath: statByPath)
            if dbIdentities[entry.url.path] == identity { continue }
            changed.append((entry, identity))
        }
        var deletedPaths = dbIdentities.keys.filter { statByPath[$0] == nil }

        let total = changed.count
        await onProgress?(0, total)

        var processed = 0
        var pendingUpserts: [(projectDir: String, summary: SessionSummary)] = []
        var pendingRecords: [SessionSummaryRecord] = []

        func flushBatch() async {
            if !pendingRecords.isEmpty, let store {
                do {
                    try await store.upsert(pendingRecords)
                } catch {
                    NSLog("[Claudoscope] Reconcile: cache upsert failed (%@); memory stays authoritative",
                          error.localizedDescription)
                }
            }
            if !pendingUpserts.isEmpty {
                await applyDelta?(ReconcileDelta(upserts: pendingUpserts, deletions: []))
            }
            pendingRecords.removeAll()
            pendingUpserts.removeAll()
        }

        func absorb(_ result: ReconcileParseResult) async {
            switch result {
            case .parsed(let projectDir, let summary, let record):
                pendingUpserts.append((projectDir, summary))
                pendingRecords.append(record)
            case .vanished(let path):
                // File disappeared between enumeration and parse: treat as a
                // deletion now instead of leaving a stale row until next launch.
                deletedPaths.append(path)
                if let pair = Self.projectDirAndSessionId(fromFilePath: path) {
                    liveKeys.remove(LiveEntryKey(projectDir: pair.projectDir, sessionId: pair.sessionId))
                }
            case .failed:
                break
            }
            processed += 1
            if processed % 50 == 0 {
                await flushBatch()
                await onProgress?(processed, total)
            }
        }

        await withTaskGroup(of: ReconcileParseResult.self) { group in
            var inflight = 0

            for (entry, identity) in changed {
                if Task.isCancelled { break }
                if inflight >= Self.maxConcurrentParses {
                    if let result = await group.next() {
                        await absorb(result)
                    }
                    inflight -= 1
                }

                let capturedEntry = entry
                let capturedIdentity = identity
                group.addTask { [parser, pricingTable] in
                    do {
                        let summary = try await parser.parseMetadata(
                            url: capturedEntry.url,
                            sessionId: capturedEntry.sessionId,
                            pricingTable: pricingTable
                        )
                        let record = try SessionSummaryRecord.make(
                            summary: summary,
                            filePath: capturedEntry.url.path,
                            projectDir: capturedEntry.dirName,
                            identity: capturedIdentity
                        )
                        return .parsed(projectDir: capturedEntry.dirName, summary: summary, record: record)
                    } catch SessionParserError.fileNotFound {
                        return .vanished(path: capturedEntry.url.path)
                    } catch {
                        NSLog("[Claudoscope] Reconcile: failed to parse %@: %@",
                              capturedEntry.url.path, error.localizedDescription)
                        return .failed
                    }
                }
                inflight += 1
            }

            for await result in group {
                await absorb(result)
            }
        }

        if Task.isCancelled {
            // Caller is about to rescan; skip the tail work. Unflushed batches
            // are dropped on purpose (their identities self-heal next pass).
            return liveKeys
        }

        await flushBatch()

        if !deletedPaths.isEmpty {
            if let store {
                do {
                    try await store.delete(filePaths: deletedPaths)
                } catch {
                    NSLog("[Claudoscope] Reconcile: cache delete failed: %@", error.localizedDescription)
                }
            }
            let pairs = deletedPaths.compactMap { Self.projectDirAndSessionId(fromFilePath: $0) }
            if !pairs.isEmpty {
                await applyDelta?(ReconcileDelta(upserts: [], deletions: pairs))
            }
        }

        await onProgress?(total, total)
        return liveKeys
    }
}

/// Decode an encoded project directory name into a human-readable project name.
/// Example: `-Users-liranb-projects-agent-hive` -> `agent-hive`
func decodeProjectName(_ encodedName: String) -> String {
    let segments = encodedName.split(separator: "-", omittingEmptySubsequences: true).map(String.init)

    var startIndex = 0

    // Look for "projects" keyword and take everything after it
    if let projectsIndex = segments.lastIndex(of: "projects"),
       projectsIndex + 1 < segments.count {
        startIndex = projectsIndex + 1
    } else if segments.count > 2,
              segments[0].lowercased() == "users" || segments[0].lowercased() == "home" {
        startIndex = 2
    }

    let meaningful = Array(segments[startIndex...])
    return meaningful.isEmpty ? encodedName : meaningful.joined(separator: "-")
}

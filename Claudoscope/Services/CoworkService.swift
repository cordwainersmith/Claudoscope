import Foundation

/// Reads Claude Cowork state from disk. Cowork is the agentic mode of the
/// Claude desktop app (Electron) and stores everything under
/// ~/Library/Application Support/Claude/.
///
/// The service is intentionally tolerant: a single corrupt file logs and is
/// skipped, never thrown — one malformed session must not hide the others.
actor CoworkService {
    static let defaultSupportDir = URL(
        fileURLWithPath: NSString(string: "~/Library/Application Support/Claude").expandingTildeInPath
    )

    private let supportDir: URL
    private let parser: SessionParser

    init(supportDir: URL = CoworkService.defaultSupportDir, parser: SessionParser = SessionParser()) {
        self.supportDir = supportDir
        self.parser = parser
    }

    // MARK: - Discovery

    /// Returns the current Cowork availability. `notConfigured` if the
    /// discovery file is missing or unparseable. `configuredButEmpty` if the
    /// owner is known but no sessions are on disk (rail stays hidden under the
    /// "in use" rule). `ready` only when at least one session exists.
    func discover() -> CoworkAvailability {
        let discoveryURL = supportDir.appendingPathComponent("cowork-enabled-cli-ops.json")
        guard let data = try? Data(contentsOf: discoveryURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ownerId = json["ownerAccountId"] as? String,
              !ownerId.isEmpty
        else {
            return .notConfigured
        }

        let projectsRoot = supportDir
            .appendingPathComponent("local-agent-mode-sessions")
            .appendingPathComponent(ownerId)

        let metadataFiles = collectMetadataFiles(under: projectsRoot)
        return metadataFiles.isEmpty
            ? .configuredButEmpty(ownerId: ownerId)
            : .ready(ownerId: ownerId)
    }

    // MARK: - Session enumeration

    /// Returns the current availability plus all readable Cowork sessions,
    /// sorted by `effectiveLastActivity` descending. One bad metadata file is
    /// logged via NSLog and excluded; the rest still load.
    func loadSessions() -> (CoworkAvailability, [CoworkSession]) {
        let availability = discover()
        guard let ownerId = availability.ownerId else {
            return (availability, [])
        }

        let projectsRoot = supportDir
            .appendingPathComponent("local-agent-mode-sessions")
            .appendingPathComponent(ownerId)

        let metadataFiles = collectMetadataFiles(under: projectsRoot)
        var sessions: [CoworkSession] = []
        sessions.reserveCapacity(metadataFiles.count)

        for (projectId, metadataURL) in metadataFiles {
            if let session = CoworkSessionDecoder.decode(metadataURL: metadataURL, projectId: projectId) {
                sessions.append(session)
            } else {
                NSLog("[CoworkService] failed to decode metadata at %@", metadataURL.path)
            }
        }

        sessions.sort { $0.effectiveLastActivity > $1.effectiveLastActivity }
        return (availability, sessions)
    }

    // MARK: - Transcript parsing

    /// Reads `audit.jsonl`, runs each line through CoworkRecordAdapter, then
    /// parses the adapted transcript twice from one temp file: parseTranscript
    /// for chat rendering and parseMetadata for the billing summary the menu
    /// bar popover consumes. The summary is rebuilt with Cowork identity
    /// fields (projectId, metadata title, isCowork) because parseMetadata
    /// derives those from the temp-file path and transcript content, which
    /// are meaningless here. Returns nil if the session has no transcript on
    /// disk. Any parser error is logged and nil returned (one bad session
    /// must not break the list).
    func loadSessionData(
        for session: CoworkSession,
        pricingTable: [String: ModelPricing]
    ) async -> (parsed: ParsedSession, summary: SessionSummary)? {
        guard let transcriptURL = session.transcriptURL else { return nil }
        do {
            let raw = try String(contentsOf: transcriptURL, encoding: .utf8)
            let adapted = raw
                .split(whereSeparator: { $0 == "\n" })
                .compactMap { CoworkRecordAdapter.adaptLine(String($0)) }

            guard !adapted.isEmpty else { return nil }

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("cowork-adapted-\(UUID().uuidString).jsonl")
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let body = adapted.joined(separator: "\n") + "\n"
            try body.write(to: tempURL, atomically: true, encoding: .utf8)

            let parsed = try await parser.parseTranscript(
                url: tempURL,
                sessionId: session.sessionId,
                projectId: session.projectId
            )
            let s = try await parser.parseMetadata(
                url: tempURL,
                sessionId: session.sessionId,
                pricingTable: pricingTable
            )
            let summary = SessionSummary(
                id: session.sessionId,
                projectId: session.projectId,
                slug: s.slug,
                title: session.displayTitle,
                firstTimestamp: s.firstTimestamp,
                lastTimestamp: s.lastTimestamp,
                messageCount: s.messageCount,
                primaryModel: s.primaryModel,
                totalInputTokens: s.totalInputTokens,
                totalOutputTokens: s.totalOutputTokens,
                totalCacheReadTokens: s.totalCacheReadTokens,
                totalCacheCreationTokens: s.totalCacheCreationTokens,
                totalCacheCreation5mTokens: s.totalCacheCreation5mTokens,
                totalCacheCreation1hTokens: s.totalCacheCreation1hTokens,
                compactionCount: s.compactionCount,
                estimatedCost: s.estimatedCost,
                hasError: s.hasError,
                modelBreakdown: s.modelBreakdown,
                toolCallCount: s.toolCallCount,
                observability: s.observability,
                isSubagent: false,
                dailyContributions: s.dailyContributions,
                isCowork: true
            )
            return (parsed, summary)
        } catch {
            NSLog("[CoworkService] transcript parse failed for %@: %@", session.sessionId, error.localizedDescription)
            return nil
        }
    }

    // MARK: - Helpers

    /// Walks {projectsRoot}/{projectId}/local_*.json. Each result is the
    /// (projectId, metadataURL) pair. Skips hidden files and non-JSON.
    private func collectMetadataFiles(under projectsRoot: URL) -> [(projectId: String, metadataURL: URL)] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: projectsRoot.path) else { return [] }

        var out: [(String, URL)] = []
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for projectDir in projectDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projectDir.path, isDirectory: &isDir), isDir.boolValue else { continue }

            guard let files = try? fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files where file.lastPathComponent.hasPrefix("local_")
                && file.pathExtension == "json" {
                out.append((projectDir.lastPathComponent, file))
            }
        }
        return out
    }
}

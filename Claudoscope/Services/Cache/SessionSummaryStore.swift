import Foundation
import GRDB

/// Persistent cache of parsed SessionSummary values, keyed by file identity,
/// so launches hydrate from SQLite instead of re-parsing every JSONL file.
///
/// A derivative store by design: a row is valid only while the file's
/// fingerprint AND the global keys (parser version, pricing key, timezone)
/// match, and the whole database can be deleted at any time with zero data
/// loss. Not an actor: DatabaseQueue is Sendable and serializes internally,
/// and every stored property is immutable.
final class SessionSummaryStore: Sendable {

    /// Whole-cache invalidation keys, stored in the single-row `meta` table.
    /// Any mismatch at open time wipes all summary rows: cached summaries bake
    /// in parser behavior (parserVersion), cost rates (pricingKey), and local
    /// calendar-day bucketing (tzIdentifier).
    struct GlobalCacheKeys: Equatable, Sendable {
        let parserVersion: Int
        let pricingKey: String
        let tzIdentifier: String
    }

    /// On-disk fingerprint a cached row must match exactly to stay valid.
    /// Parent fields apply only to context-fork subagent files (acompact /
    /// aside), whose parse output also depends on the parent transcript;
    /// nil for everything else. Always compared with Swift ==, never in SQL,
    /// so nil parent == nil parent matches and NULL semantics can't bite.
    struct FileIdentity: Equatable, Sendable {
        let size: Int64
        let mtime: Double
        let parentSize: Int64?
        let parentMtime: Double?
    }

    let dbWriter: any DatabaseWriter

    /// Live-stat fingerprint for one file, used by the watcher write-through
    /// path. The reconcile pass computes identities from its own enumeration
    /// snapshot instead, so a context-fork pair is fingerprinted from one
    /// consistent directory listing. Returns nil when the file can't be
    /// statted (vanished between the event and the handler).
    static func statIdentity(for url: URL) -> FileIdentity? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let mdate = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? Int64 else { return nil }
        var parentSize: Int64?
        var parentMtime: Double?
        if SessionParser.isContextForkSubagentFile(url) {
            let parentPath = SessionParser.parentTranscriptURL(forSubagentFile: url).path
            if let pAttrs = try? fm.attributesOfItem(atPath: parentPath),
               let pDate = pAttrs[.modificationDate] as? Date,
               let pSize = pAttrs[.size] as? Int64 {
                parentSize = pSize
                parentMtime = pDate.timeIntervalSince1970
            }
        }
        return FileIdentity(
            size: size, mtime: mdate.timeIntervalSince1970,
            parentSize: parentSize, parentMtime: parentMtime
        )
    }

    /// Production location. Plain path (app-sandbox is false); shared between
    /// `swift run` dev builds and the installed app, which the global-key
    /// check and busy timeout make safe.
    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Claudoscope/cache.sqlite")
    }

    /// Opens (creating if needed) the cache at `dbURL`. A corrupt or
    /// unopenable file is deleted (with its -wal/-shm siblings) and recreated
    /// once; if that also fails, returns nil and the app runs without a cache,
    /// which degrades to today's full-parse behavior.
    static func open(at dbURL: URL) -> SessionSummaryStore? {
        let fm = FileManager.default
        try? fm.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            return try SessionSummaryStore(path: dbURL.path)
        } catch {
            NSLog("[Claudoscope] SummaryCache: open failed (%@), deleting and recreating %@",
                  error.localizedDescription, dbURL.path)
        }
        for suffix in ["", "-wal", "-shm"] {
            try? fm.removeItem(atPath: dbURL.path + suffix)
        }
        do {
            return try SessionSummaryStore(path: dbURL.path)
        } catch {
            NSLog("[Claudoscope] SummaryCache: reopen failed (%@), running without cache",
                  error.localizedDescription)
            return nil
        }
    }

    private convenience init(path: String) throws {
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            // fetchOne, not execute: the pragma returns a row.
            _ = try String.fetchOne(db, sql: "PRAGMA journal_mode = WAL")
        }
        try self.init(DatabaseQueue(path: path, configuration: config))
    }

    /// Runs migrations on `writer`. Test seam: pass an in-memory or temp-dir
    /// DatabaseQueue. Production goes through `open(at:)`.
    init(_ writer: any DatabaseWriter) throws {
        self.dbWriter = writer
        try Self.migrator.migrate(writer)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE meta (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    parser_version INTEGER NOT NULL,
                    pricing_key TEXT NOT NULL,
                    tz_identifier TEXT NOT NULL,
                    last_full_scan_at REAL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE session_summaries (
                    file_path TEXT PRIMARY KEY,
                    project_dir TEXT NOT NULL,
                    session_id TEXT NOT NULL,
                    file_size INTEGER NOT NULL,
                    file_mtime REAL NOT NULL,
                    parent_file_size INTEGER,
                    parent_file_mtime REAL,
                    is_subagent INTEGER NOT NULL,
                    last_timestamp TEXT NOT NULL,
                    summary_json BLOB NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_summaries_project ON session_summaries(project_dir)")
        }
        return migrator
    }

    // MARK: - Meta / global invalidation

    /// Compares the stored global keys against `keys`; on any mismatch, wipes
    /// all summary rows and stores the new keys in one transaction. Returns
    /// true when a wipe happened. A fresh database seeds the keys and returns
    /// false (nothing to wipe).
    func checkAndApplyGlobalKeys(_ keys: GlobalCacheKeys) async throws -> Bool {
        try await dbWriter.write { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT parser_version, pricing_key, tz_identifier FROM meta WHERE id = 1"
            ) else {
                try db.execute(
                    sql: "INSERT INTO meta (id, parser_version, pricing_key, tz_identifier) VALUES (1, ?, ?, ?)",
                    arguments: [keys.parserVersion, keys.pricingKey, keys.tzIdentifier]
                )
                return false
            }
            let stored = GlobalCacheKeys(
                parserVersion: row["parser_version"],
                pricingKey: row["pricing_key"],
                tzIdentifier: row["tz_identifier"]
            )
            if stored == keys { return false }
            try db.execute(sql: "DELETE FROM session_summaries")
            try db.execute(
                sql: "UPDATE meta SET parser_version = ?, pricing_key = ?, tz_identifier = ? WHERE id = 1",
                arguments: [keys.parserVersion, keys.pricingKey, keys.tzIdentifier]
            )
            return true
        }
    }

    func setLastFullScanAt(_ date: Date) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: "UPDATE meta SET last_full_scan_at = ? WHERE id = 1",
                arguments: [date.timeIntervalSince1970]
            )
        }
    }

    // MARK: - Rows

    /// All rows decoded for launch hydration. Blobs that fail to decode (a
    /// model field changed without a parserVersion bump) are reported by path,
    /// not returned; the caller deletes them so they become plain cache misses
    /// for the reconcile pass.
    func fetchAllForHydration() async throws
        -> (rows: [(projectDir: String, summary: SessionSummary)], undecodablePaths: [String]) {
        try await dbWriter.read { db in
            let decoder = JSONDecoder()
            var rows: [(projectDir: String, summary: SessionSummary)] = []
            var undecodable: [String] = []
            for record in try SessionSummaryRecord.fetchAll(db) {
                if let summary = try? decoder.decode(SessionSummary.self, from: record.summaryJson) {
                    rows.append((record.projectDir, summary))
                } else {
                    undecodable.append(record.filePath)
                }
            }
            return (rows, undecodable)
        }
    }

    /// File fingerprints for every cached row, keyed by absolute path.
    /// No blob decoding: this is the reconcile pass's hot lookup.
    func fetchIdentities() async throws -> [String: FileIdentity] {
        try await dbWriter.read { db in
            var result: [String: FileIdentity] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT file_path, file_size, file_mtime, parent_file_size, parent_file_mtime
                FROM session_summaries
                """)
            for row in rows {
                result[row["file_path"]] = FileIdentity(
                    size: row["file_size"],
                    mtime: row["file_mtime"],
                    parentSize: row["parent_file_size"],
                    parentMtime: row["parent_file_mtime"]
                )
            }
            return result
        }
    }

    /// One write transaction per call; callers batch (the reconcile pass
    /// aligns batches with its progress cadence).
    func upsert(_ records: [SessionSummaryRecord]) async throws {
        guard !records.isEmpty else { return }
        try await dbWriter.write { db in
            for record in records {
                try record.upsert(db)
            }
        }
    }

    func delete(filePaths: [String]) async throws {
        guard !filePaths.isEmpty else { return }
        try await dbWriter.write { db in
            // Chunked to stay under SQLite's bound-parameter limit.
            var index = 0
            while index < filePaths.count {
                let chunk = Array(filePaths[index..<min(index + 500, filePaths.count)])
                try SessionSummaryRecord.deleteAll(db, keys: chunk)
                index += 500
            }
        }
    }
}

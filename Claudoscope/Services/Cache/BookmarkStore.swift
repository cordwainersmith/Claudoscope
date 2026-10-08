import Foundation
import GRDB

/// Persistent store for user data (bookmarks and notes). Separate file from
/// the summary cache on purpose: `cache.sqlite` is a derivative store that
/// `SessionSummaryStore.open` deletes and recreates on corruption, and this
/// data cannot be rebuilt from transcripts. Open failure here logs and
/// returns nil; it never deletes the file.
final class BookmarkStore: Sendable {

    let dbWriter: any DatabaseWriter

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Claudoscope/user.sqlite")
    }

    static func open(at dbURL: URL) -> BookmarkStore? {
        try? FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            return try BookmarkStore(path: dbURL.path)
        } catch {
            NSLog("[Claudoscope] BookmarkStore: open failed (%@), bookmarks unavailable this launch: %@",
                  error.localizedDescription, dbURL.path)
            return nil
        }
    }

    private convenience init(path: String) throws {
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            _ = try String.fetchOne(db, sql: "PRAGMA journal_mode = WAL")
        }
        try self.init(DatabaseQueue(path: path, configuration: config))
    }

    /// Runs migrations on `writer`. Test seam: pass an in-memory DatabaseQueue.
    init(_ writer: any DatabaseWriter) throws {
        self.dbWriter = writer
        try Self.migrator.migrate(writer)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE bookmarks (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT NOT NULL,
                    project_id TEXT NOT NULL,
                    record_uuid TEXT NOT NULL,
                    session_title TEXT NOT NULL,
                    excerpt TEXT NOT NULL,
                    note TEXT NOT NULL DEFAULT '',
                    created_at DOUBLE NOT NULL,
                    updated_at DOUBLE NOT NULL,
                    UNIQUE(session_id, record_uuid)
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_bookmarks_session ON bookmarks(session_id)")
        }
        return migrator
    }

    // MARK: - Queries

    /// Newest first.
    func fetchAll() async throws -> [Bookmark] {
        try await dbWriter.read { db in
            try Bookmark.fetchAll(db, sql: "SELECT * FROM bookmarks ORDER BY created_at DESC, id DESC")
        }
    }

    func fetch(sessionId: String) async throws -> [Bookmark] {
        try await dbWriter.read { db in
            try Bookmark.fetchAll(
                db, sql: "SELECT * FROM bookmarks WHERE session_id = ? ORDER BY created_at DESC, id DESC",
                arguments: [sessionId]
            )
        }
    }

    /// Returns the inserted row with its id. Throws on a duplicate
    /// (session_id, record_uuid) pair.
    func insert(_ bookmark: Bookmark) async throws -> Bookmark {
        try await dbWriter.write { db in
            var row = bookmark
            try row.insert(db)
            return row
        }
    }

    func updateNote(id: Int64, note: String) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: "UPDATE bookmarks SET note = ?, updated_at = ? WHERE id = ?",
                arguments: [note, Date().timeIntervalSince1970, id]
            )
        }
    }

    func delete(id: Int64) async throws {
        _ = try await dbWriter.write { db in
            try Bookmark.deleteOne(db, key: id)
        }
    }
}

import Foundation
import GRDB

extension SessionSummaryStore {

    /// Inserts `record` unless the session already has an open wait. Returns
    /// true when a row was inserted.
    @discardableResult
    func openWait(_ record: FleetWaitRecord) async throws -> Bool {
        try await dbWriter.write { db in
            let open = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM fleet_waits WHERE session_id = ? AND ended_at IS NULL
                """, arguments: [record.sessionId]) ?? 0
            guard open == 0 else { return false }
            var row = record
            try row.insert(db)
            return true
        }
    }

    func closeWait(sessionId: String, at: Date) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: """
                UPDATE fleet_waits SET ended_at = ? WHERE session_id = ? AND ended_at IS NULL
                """, arguments: [at.timeIntervalSince1970, sessionId])
        }
    }

    func fetchWaits(startedAfter: Date) async throws -> [FleetWaitRecord] {
        try await dbWriter.read { db in
            try FleetWaitRecord.fetchAll(db, sql: """
                SELECT * FROM fleet_waits WHERE started_at >= ? ORDER BY started_at
                """, arguments: [startedAfter.timeIntervalSince1970])
        }
    }

    /// Waits still open, e.g. left by a previous run, so the store can close
    /// them when the transcript moves.
    func fetchOpenWaits() async throws -> [FleetWaitRecord] {
        try await dbWriter.read { db in
            try FleetWaitRecord.fetchAll(db, sql: "SELECT * FROM fleet_waits WHERE ended_at IS NULL")
        }
    }

    func pruneWaits(startedBefore: Date) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: "DELETE FROM fleet_waits WHERE started_at < ?",
                           arguments: [startedBefore.timeIntervalSince1970])
        }
    }
}

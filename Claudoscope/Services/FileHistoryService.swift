import Foundation

/// A per-file rollup of Claude Code's checkpoint/file-history snapshots for one
/// session. Derived from `file-history-snapshot` records (the in-transcript index
/// of edits Claude Code's file tools made); the actual content lives under
/// ~/.claude/file-history/<sessionId>/ and is not read here (phase 2).
struct FileChangeSummary: Identifiable, Sendable {
    var id: String { path }
    let path: String            // project-relative path (trackedFileBackups key)
    let latestVersion: Int
    let lastBackupTime: String? // ISO-8601, from the backup's backupTime
}

/// Pure aggregation over a session's records. Stateless; safe to call from a view.
enum FileHistoryService {

    /// One `FileChangeSummary` per tracked file, taking the highest version and
    /// most recent backup time seen across the session's cumulative snapshots.
    /// Returns [] when there are no snapshot records (e.g. a session with no
    /// Claude-made edits, or lite-decoded records where `snapshot` is nil).
    static func summarize(records: [ParsedRecordRaw]) -> [FileChangeSummary] {
        var maxVersionByPath: [String: Int] = [:]
        var lastTimeByPath: [String: String] = [:]

        for record in records where record.type == .fileHistorySnapshot {
            guard let backups = record.snapshot?.trackedFileBackups else { continue }
            for (path, backup) in backups {
                let version = backup.version ?? 1
                maxVersionByPath[path] = max(maxVersionByPath[path] ?? 0, version)
                if let time = backup.backupTime, time > (lastTimeByPath[path] ?? "") {
                    lastTimeByPath[path] = time
                }
            }
        }

        return maxVersionByPath.keys.sorted().map { path in
            FileChangeSummary(
                path: path,
                latestVersion: maxVersionByPath[path] ?? 1,
                lastBackupTime: lastTimeByPath[path]
            )
        }
    }

    /// Message IDs (assistant-turn uuids) that produced a backup. Used to mark
    /// the turns that created a checkpoint in the chat. Only `isSnapshotUpdate`
    /// records carry a fresh backup; the cumulative (false) snapshots do not.
    static func checkpointMessageIds(records: [ParsedRecordRaw]) -> Set<String> {
        var ids: Set<String> = []
        for record in records where record.type == .fileHistorySnapshot && record.isSnapshotUpdate == true {
            if let messageId = record.messageId { ids.insert(messageId) }
        }
        return ids
    }
}

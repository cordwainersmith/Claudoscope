import Foundation

/// Describes how complete the local transcript data is, so the Analytics view
/// can say plainly that the cost estimate covers only what's on this Mac.
///
/// Two gaps make the estimate lower than the real bill: Claude Code deletes
/// transcripts past `cleanupPeriodDays` (default 30), and spend on other
/// machines, claude.ai/code, or CI never writes local JSONL. `history.jsonl`
/// still lists sessions whose transcripts are gone — the difference between
/// those and the sessions we parsed is the visible "missing" count.
struct DataCoverage: Sendable, Equatable {
    let oldestTranscriptDate: Date?
    let missingTranscriptCount: Int
    let cleanupPeriodDays: Int?              // nil = unset in settings.json

    var effectiveCleanupDays: Int { cleanupPeriodDays ?? 30 }
    var isWarning: Bool { missingTranscriptCount > 0 || effectiveCleanupDays <= 30 }

    static func compute(
        historyEntries: [HistoryEntry],
        knownSessionIds: Set<String>,
        cleanupPeriodDays: Int?,
        oldestFirstTimestamp: String?
    ) -> DataCoverage {
        let historyIds = Set(historyEntries.compactMap(\.sessionId))
        let missing = historyIds.subtracting(knownSessionIds).count
        return DataCoverage(
            oldestTranscriptDate: oldestFirstTimestamp.flatMap(ISO8601.parse),
            missingTranscriptCount: missing,
            cleanupPeriodDays: cleanupPeriodDays
        )
    }
}

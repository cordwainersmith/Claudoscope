import Foundation
import GRDB

/// One row of the `session_summaries` table: cache-identity columns plus the
/// whole SessionSummary as a JSON blob. Identity semantics (what makes a row
/// valid) live in SessionSummaryStore.FileIdentity; this type is row mapping.
struct SessionSummaryRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "session_summaries"

    var filePath: String
    var projectDir: String
    var sessionId: String
    var fileSize: Int64
    var fileMtime: Double
    var parentFileSize: Int64?
    var parentFileMtime: Double?
    var isSubagent: Bool
    var lastTimestamp: String
    var summaryJson: Data

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case projectDir = "project_dir"
        case sessionId = "session_id"
        case fileSize = "file_size"
        case fileMtime = "file_mtime"
        case parentFileSize = "parent_file_size"
        case parentFileMtime = "parent_file_mtime"
        case isSubagent = "is_subagent"
        case lastTimestamp = "last_timestamp"
        case summaryJson = "summary_json"
    }

    static func make(
        summary: SessionSummary,
        filePath: String,
        projectDir: String,
        identity: SessionSummaryStore.FileIdentity
    ) throws -> SessionSummaryRecord {
        SessionSummaryRecord(
            filePath: filePath,
            projectDir: projectDir,
            sessionId: summary.id,
            fileSize: identity.size,
            fileMtime: identity.mtime,
            parentFileSize: identity.parentSize,
            parentFileMtime: identity.parentMtime,
            isSubagent: summary.isSubagent,
            lastTimestamp: summary.lastTimestamp,
            summaryJson: try JSONEncoder().encode(CachedSummaryEnvelope(summary: summary))
        )
    }
}

/// The blob stored in `summary_json`. Stamping each row with the parser
/// version that wrote it closes a hole the global meta key cannot: an older
/// build still running beside a newer one (e.g. during a Debug swap) writes
/// rows under the newer meta version. Those rows either lack the envelope or
/// carry the old version, and hydration rejects both.
struct CachedSummaryEnvelope: Codable {
    var parserVersion: Int = SessionParser.parserVersion
    let summary: SessionSummary

    /// The summary, or nil when the blob is not an envelope written by this
    /// parser version.
    static func decodeCurrent(_ data: Data, decoder: JSONDecoder) -> SessionSummary? {
        guard let envelope = try? decoder.decode(CachedSummaryEnvelope.self, from: data),
              envelope.parserVersion == SessionParser.parserVersion else { return nil }
        return envelope.summary
    }
}

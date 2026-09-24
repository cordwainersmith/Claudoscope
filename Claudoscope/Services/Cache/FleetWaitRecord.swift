import Foundation
import GRDB

/// One stretch of an agent waiting on the user, from the moment a hook or the
/// registry reported the wait to the moment the transcript moved again. The
/// turn fields snapshot the prompt cache at the start so a late answer can be
/// priced as a cold restart.
struct FleetWaitRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    static let databaseTableName = "fleet_waits"

    var id: Int64?
    var sessionId: String
    var projectId: String
    /// permission | elicitation | block | your_turn | registry_waiting
    var kind: String
    var startedAt: Double
    var endedAt: Double?
    var contextTokens: Int?
    var cacheTtlSeconds: Int?
    var turnTimestamp: Double?
    var model: String?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case projectId = "project_id"
        case kind
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case contextTokens = "context_tokens"
        case cacheTtlSeconds = "cache_ttl_seconds"
        case turnTimestamp = "turn_timestamp"
        case model
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

import Foundation
import GRDB

/// A pinned user or assistant turn with an optional note. User data, not a
/// rebuildable cache: lives in `user.sqlite` (BookmarkStore), never in
/// `cache.sqlite`, which is wiped on corruption and on global-key changes.
struct Bookmark: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable, Equatable {
    static let databaseTableName = "bookmarks"

    var id: Int64?
    var sessionId: String
    var projectId: String
    var recordUuid: String
    /// Session title at bookmark time so the cross-session list renders without a parse.
    var sessionTitle: String
    /// First 200 chars of the message text, same purpose.
    var excerpt: String
    var note: String
    var createdAt: Double
    var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case projectId = "project_id"
        case recordUuid = "record_uuid"
        case sessionTitle = "session_title"
        case excerpt
        case note
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    static let excerptLength = 200

    /// The stored preview of a turn: the visible prompt for a user record
    /// (harness tags stripped), the first text block for an assistant record.
    /// May be empty (a system-reminder-only prompt); the uuid is the key, not
    /// the text, so an empty excerpt is still a valid bookmark.
    static func excerpt(from record: ParsedRecordRaw) -> String {
        let text: String
        switch record.type {
        case .user:
            text = strippedUserText(record.message?.content?.textContent)
        case .assistant:
            if case .blocks(let blocks) = record.message?.content,
               let first = blocks.first(where: { $0.type == "text" && !($0.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                text = (first.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                text = (record.message?.content?.textContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        default:
            text = ""
        }
        return String(text.prefix(excerptLength))
    }
}

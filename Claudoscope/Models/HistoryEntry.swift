import Foundation

struct HistoryEntry: Identifiable, Sendable {
    let id: String
    let type: String
    let sessionId: String?
    let project: String?
    let projectId: String?
    let timestamp: Date
    let display: String
}

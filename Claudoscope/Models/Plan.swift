import Foundation

// MARK: - Plan Summary (lightweight for sidebar)

struct PlanSummary: Identifiable, Sendable {
    var id: String { filename }
    let filename: String
    let title: String
    let projectHint: String?
    let createdAt: Date?
    let sizeBytes: Int
}

// MARK: - Plan Detail (full content)

struct PlanDetail: Sendable {
    let filename: String
    let title: String
    let content: String
}

import Foundation

/// What a sidebar row draws, lifted out of `SessionSummary`. SwiftUI diffs a
/// view's inputs on every store change, and comparing whole summaries (model
/// breakdowns, daily contributions, attribution) for every session in the
/// corpus was a third of main-thread time while a session streamed.
struct SessionRowModel: Identifiable, Equatable {
    let id: String
    let title: String
    let lastDate: Date?
    let messageCount: Int
    let toolCallCount: Int
    let errorLabels: [String]
    let hasIdleZombieGap: Bool
    let isWorktree: Bool
    let worktreeHelp: String
    let prNumber: Int?
    let prUrl: String?
    let modelFamily: String?

    init(_ session: SessionSummary) {
        id = session.id
        title = session.title
        lastDate = ISO8601.parse(session.lastTimestamp)
        messageCount = session.messageCount
        toolCallCount = session.toolCallCount
        errorLabels = session.observability.errorClassifications.map(\.label)
        hasIdleZombieGap = session.observability.hasIdleZombieGap
        // The worktree-state record names the checkout; observability only
        // infers one from worktree tool use, so prefer the record.
        isWorktree = session.worktreeName != nil || session.observability.isWorktreeSession
        if let name = session.worktreeName, let branch = session.worktreeBranch {
            worktreeHelp = "Worktree \(name) on branch \(branch)"
        } else if let name = session.worktreeName {
            worktreeHelp = "Worktree \(name)"
        } else {
            worktreeHelp = "Session uses a git worktree"
        }
        prNumber = session.prNumber
        prUrl = session.prUrl
        modelFamily = session.primaryModel.map { getModelFamily($0) }
    }

    /// Rows for one project's sessions. Subagents are hidden from the sidebar:
    /// their UUID titles add noise and the parent row already represents them.
    static func rows(_ sessions: [SessionSummary]) -> [SessionRowModel] {
        sessions.compactMap { $0.isSubagent ? nil : SessionRowModel($0) }
    }
}

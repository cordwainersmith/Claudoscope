import Foundation

/// Pure derivation for continued sessions: a conversation handed off to a
/// background job (Claude Code 2.1.296), whose transcript carries copies of
/// the parent's records. No IO, no store state, so the rules are unit-testable
/// in isolation; SessionStore owns the map and schedules the re-reads.
enum ContinuationEngine {

    /// Job session id → the parent transcript it was continued from, built from
    /// the parents' `continuedInSessionId`.
    static func parents(
        in sessionsByProject: [String: [SessionSummary]],
        transcriptURL: (_ projectId: String, _ sessionId: String) -> URL
    ) -> [String: URL] {
        var parents: [String: URL] = [:]
        for (projectId, sessions) in sessionsByProject {
            for session in sessions {
                if let job = session.continuedInSessionId {
                    parents[job] = transcriptURL(projectId, session.id)
                }
            }
        }
        return parents
    }

    /// Re-read memo key for a job linked to `parentId` ("" when it has none).
    static func attemptKey(_ parentId: String?) -> String {
        parentId ?? ""
    }

    /// Whether a job's summary must be re-read: it was checked against a
    /// different parent than the one it is linked to now (nil: not linked), and
    /// no re-read against that link was tried yet. `lastAttempt` is the memo
    /// key of the last try, so a parent that can't be read doesn't loop.
    static func needsReread(_ job: SessionSummary, linkedParentId: String?, lastAttempt: String?) -> Bool {
        job.continuedFromSessionId != linkedParentId && lastAttempt != attemptKey(linkedParentId)
    }
}

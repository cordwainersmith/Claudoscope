import XCTest
@testable import Claudoscope

/// The job → parent map and the re-read rule SessionStore applies whenever a
/// summary lands or goes: a job is re-read when it was checked against a
/// different parent than it is linked to now, once per link.
final class ContinuationEngineTests: XCTestCase {

    private func summary(id: String, continuedIn: String? = nil, continuedFrom: String? = nil) -> SessionSummary {
        SessionSummary(
            id: id, projectId: "p", slug: nil, title: id,
            firstTimestamp: "", lastTimestamp: "", messageCount: 1, primaryModel: nil,
            totalInputTokens: 0, totalOutputTokens: 0, totalCacheReadTokens: 0,
            totalCacheCreationTokens: 0, totalCacheCreation5mTokens: 0,
            totalCacheCreation1hTokens: 0, compactionCount: 0, estimatedCost: 0,
            hasError: false, modelBreakdown: [], toolCallCount: 0,
            observability: .empty, isSubagent: false, dailyContributions: [],
            continuedInSessionId: continuedIn, continuedFromSessionId: continuedFrom
        )
    }

    func testParentsMapEachJobToItsParentTranscript() {
        let parents = ContinuationEngine.parents(
            in: [
                "proj-a": [summary(id: "parent", continuedIn: "job"), summary(id: "other")],
                "proj-b": [summary(id: "job")],
            ],
            transcriptURL: { URL(fileURLWithPath: "/p/\($0)/\($1).jsonl") }
        )
        XCTAssertEqual(parents, ["job": URL(fileURLWithPath: "/p/proj-a/parent.jsonl")])
    }

    func testRereadWhenCheckedAgainstAnotherParent() {
        XCTAssertTrue(ContinuationEngine.needsReread(summary(id: "job"), linkedParentId: "parent", lastAttempt: nil),
                      "parsed before its parent was seen")
        XCTAssertFalse(ContinuationEngine.needsReread(summary(id: "job", continuedFrom: "parent"),
                                                      linkedParentId: "parent", lastAttempt: nil))
        XCTAssertTrue(ContinuationEngine.needsReread(summary(id: "job", continuedFrom: "parent"),
                                                     linkedParentId: nil, lastAttempt: nil),
                      "the parent went away, so the job carries the copied spend again")
        XCTAssertFalse(ContinuationEngine.needsReread(summary(id: "plain"), linkedParentId: nil, lastAttempt: nil))
    }

    func testRereadIsTriedOncePerLink() {
        XCTAssertFalse(ContinuationEngine.needsReread(summary(id: "job"), linkedParentId: "parent",
                                                      lastAttempt: ContinuationEngine.attemptKey("parent")),
                       "a parent that can't be read must not loop")
        XCTAssertTrue(ContinuationEngine.needsReread(summary(id: "job", continuedFrom: "parent"),
                                                     linkedParentId: nil,
                                                     lastAttempt: ContinuationEngine.attemptKey("parent")),
                      "a changed link is tried even after an earlier attempt")
    }
}

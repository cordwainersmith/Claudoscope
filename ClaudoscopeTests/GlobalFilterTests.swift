import XCTest
@testable import Claudoscope

/// Unit tests for `SessionStore`'s global project + date filter, which scopes
/// the sessions/tools/timeline/plans sidebars while leaving the base
/// `projects`/`sessionsByProject`/`plans`/`timelineEntries` collections (read by
/// the popover) untouched.
@MainActor
final class GlobalFilterTests: XCTestCase {
    var store: SessionStore!

    override func setUp() async throws {
        try await super.setUp()
        store = SessionStore()
    }

    private func makeSession(id: String, lastTimestamp: String, isSubagent: Bool = false) -> SessionSummary {
        SessionSummary(
            id: id,
            projectId: "proj",
            slug: nil,
            title: id,
            firstTimestamp: lastTimestamp,
            lastTimestamp: lastTimestamp,
            messageCount: 1,
            primaryModel: nil,
            totalInputTokens: 0,
            totalOutputTokens: 0,
            totalCacheReadTokens: 0,
            totalCacheCreationTokens: 0,
            totalCacheCreation5mTokens: 0,
            totalCacheCreation1hTokens: 0,
            compactionCount: 0,
            estimatedCost: 0,
            hasError: false,
            modelBreakdown: [],
            toolCallCount: 0,
            observability: .empty,
            isSubagent: isSubagent,
            dailyContributions: []
        )
    }

    func testDefaultFilterIsInactiveAndPassesDataThrough() {
        let projectA = Project(id: "a", name: "Alpha", path: "/a", sessionCount: 1)
        store.projects = [projectA]
        store.sessionsByProject = ["a": [makeSession(id: "s1", lastTimestamp: "2026-07-01T00:00:00Z")]]

        XCTAssertFalse(store.globalFilterActive)
        XCTAssertEqual(store.filteredProjects.map(\.id), ["a"])
        XCTAssertEqual(store.filteredSessionsByProject["a"]?.map(\.id), ["s1"])
    }

    func testProjectFilterNarrowsSessionsByProjectAndDropsEmptyProjects() {
        let projectA = Project(id: "a", name: "Alpha", path: "/a", sessionCount: 1)
        let projectB = Project(id: "b", name: "Beta", path: "/b", sessionCount: 1)
        store.projects = [projectA, projectB]
        store.sessionsByProject = [
            "a": [makeSession(id: "s1", lastTimestamp: "2026-07-01T00:00:00Z")],
            "b": [makeSession(id: "s2", lastTimestamp: "2026-07-01T00:00:00Z")]
        ]

        store.globalFilterProjectId = "a"

        XCTAssertTrue(store.globalFilterActive)
        XCTAssertEqual(store.filteredProjects.map(\.id), ["a"])
        XCTAssertNil(store.filteredSessionsByProject["b"])
        XCTAssertEqual(store.filteredSessionsByProject["a"]?.map(\.id), ["s1"])
    }

    func testDateRangeExcludesSessionsOutsideWindow() {
        let projectA = Project(id: "a", name: "Alpha", path: "/a", sessionCount: 2)
        store.projects = [projectA]
        store.sessionsByProject = [
            "a": [
                makeSession(id: "recent", lastTimestamp: ISO8601.noFractional.string(from: Date())),
                makeSession(id: "old", lastTimestamp: "2020-01-01T00:00:00Z")
            ]
        ]

        store.globalFilterRange = .sevenDays

        XCTAssertEqual(store.filteredSessionsByProject["a"]?.map(\.id), ["recent"])
    }

    func testBaseCollectionsUnaffectedByGlobalFilter() {
        let projectA = Project(id: "a", name: "Alpha", path: "/a", sessionCount: 1)
        store.projects = [projectA]
        store.sessionsByProject = ["a": [makeSession(id: "s1", lastTimestamp: "2020-01-01T00:00:00Z")]]

        store.globalFilterProjectId = "does-not-exist"
        store.globalFilterRange = .today

        // Base collections (read by the popover) must stay untouched.
        XCTAssertEqual(store.projects.map(\.id), ["a"])
        XCTAssertEqual(store.sessionsByProject["a"]?.map(\.id), ["s1"])
    }

    func testPlansFilterMatchesProjectHintAndDateRange() {
        let projectA = Project(id: "a", name: "Alpha", path: "/a", sessionCount: 0)
        store.projects = [projectA]
        store.plans = [
            PlanSummary(filename: "1.md", title: "Alpha — Do thing", projectHint: "Alpha", createdAt: Date(), sizeBytes: 0),
            PlanSummary(filename: "2.md", title: "Beta — Do thing", projectHint: "Beta", createdAt: Date(), sizeBytes: 0),
            PlanSummary(filename: "3.md", title: "No hint", projectHint: nil, createdAt: Date(), sizeBytes: 0)
        ]

        store.globalFilterProjectId = "a"

        XCTAssertEqual(store.filteredPlans.map(\.filename), ["1.md"])
    }

    func testTimelineFilterMatchesProjectIdAndDateRange() {
        store.timelineEntries = [
            HistoryEntry(id: "1", type: "conversation", sessionId: nil, project: "/x/a", projectId: "a", timestamp: Date(), display: "hi"),
            HistoryEntry(id: "2", type: "conversation", sessionId: nil, project: "/x/b", projectId: "b", timestamp: Date(), display: "hi")
        ]

        store.globalFilterProjectId = "a"

        XCTAssertEqual(store.filteredTimelineEntries.map(\.id), ["1"])
    }
}

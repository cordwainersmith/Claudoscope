import XCTest
@testable import Claudoscope

/// Tests for the cross-session attribution fold: day windowing, the skill-tag
/// normalizer, and the two independent remainders.
final class AttributionEngineTests: XCTestCase {

    // MARK: - Fixtures

    private func day(
        _ date: String,
        cost: Double,
        skills: [(String, Double)] = [],
        mcps: [(String, String, Double)] = []
    ) -> DailyContribution {
        DailyContribution(
            date: date,
            inputTokens: 100, outputTokens: 200, cacheReadTokens: 0,
            cacheCreationTokens: 0, cacheCreation5mTokens: 0, cacheCreation1hTokens: 0,
            estimatedCost: cost,
            modelBreakdown: [],
            skillBreakdown: skills.map {
                SkillAttribution(skill: $0.0, inputTokens: 100, outputTokens: 200,
                                 cacheReadTokens: 0, estimatedCost: $0.1, turnCount: 1)
            },
            mcpBreakdown: mcps.map {
                McpAttribution(server: $0.0, tool: $0.1, inputTokens: 100, outputTokens: 200,
                               cacheReadTokens: 0, estimatedCost: $0.2, turnCount: 1)
            }
        )
    }

    private func session(
        _ id: String,
        days: [DailyContribution],
        agent: String? = nil,
        isSubagent: Bool = false
    ) -> SessionSummary {
        SessionSummary(
            id: id, projectId: "p", slug: nil, title: id,
            firstTimestamp: "", lastTimestamp: "", messageCount: 1, primaryModel: nil,
            totalInputTokens: 0, totalOutputTokens: 0, totalCacheReadTokens: 0,
            totalCacheCreationTokens: 0, totalCacheCreation5mTokens: 0,
            totalCacheCreation1hTokens: 0, compactionCount: 0,
            estimatedCost: days.reduce(0) { $0 + $1.estimatedCost },
            hasError: false, modelBreakdown: [], toolCallCount: 0,
            observability: .empty, isSubagent: isSubagent, dailyContributions: days,
            attributionAgent: agent
        )
    }

    private func skillEntry(_ name: String) -> SkillEntry {
        SkillEntry(name: name, displayName: name, description: nil,
                   metadata: [:], body: "", sizeBytes: 0)
    }

    // MARK: - Windowing

    func testDayRangeExcludesOutOfRangeDays() {
        let s = session("s1", days: [
            day("2026-09-01", cost: 10, skills: [("ship", 4)]),
            day("2026-09-10", cost: 10, skills: [("ship", 6)]),
        ])

        let all = AttributionEngine.aggregate(sessions: [s])
        XCTAssertEqual(all.totalCost, 20, accuracy: 1e-9)
        XCTAssertEqual(all.skills.first?.estimatedCost ?? 0, 10, accuracy: 1e-9)

        // Half-open [from, to): 2026-09-10 is excluded by an exclusive bound.
        let windowed = AttributionEngine.aggregate(
            sessions: [s], fromDay: "2026-09-01", toDay: "2026-09-10"
        )
        XCTAssertEqual(windowed.totalCost, 10, accuracy: 1e-9)
        XCTAssertEqual(windowed.skills.first?.estimatedCost ?? 0, 4, accuracy: 1e-9)
    }

    /// A session whose billed days all fall outside the window contributes
    /// nothing, rather than leaking its lifetime cost into the denominator.
    func testSessionEntirelyOutOfWindowIsDropped() {
        let s = session("s1", days: [day("2026-01-01", cost: 99, skills: [("ship", 99)])])
        let r = AttributionEngine.aggregate(sessions: [s], fromDay: "2026-09-01", toDay: "2026-09-30")
        XCTAssertEqual(r.totalCost, 0)
        XCTAssertTrue(r.skills.isEmpty)
    }

    // MARK: - Skill normalizer

    func testBareAndQualifiedTagsFoldToOneRow() {
        let s = session("s1", days: [
            day("2026-09-10", cost: 10, skills: [
                ("frontend-design", 3),
                ("frontend-design:frontend-design", 2),
            ]),
        ])
        let r = AttributionEngine.aggregate(sessions: [s])
        XCTAssertEqual(r.skills.count, 1, "the same skill in both tag forms must be one row")
        XCTAssertEqual(r.skills.first?.skill, "frontend-design")
        XCTAssertEqual(r.skills.first?.estimatedCost ?? 0, 5, accuracy: 1e-9)
        XCTAssertEqual(r.skills.first?.turnCount, 2)
    }

    func testCanonicalSkillKey() {
        XCTAssertEqual(AttributionEngine.canonicalSkillKey("dataviz"), "dataviz")
        XCTAssertEqual(AttributionEngine.canonicalSkillKey("claude-blog:blog-write"), "blog-write")
        XCTAssertEqual(AttributionEngine.canonicalSkillKey("a:b:c"), "c")
        // Degenerate input must not produce an empty key.
        XCTAssertEqual(AttributionEngine.canonicalSkillKey("trailing:"), "trailing:")
    }

    func testIsInstalledMarksTagsWithNoMatchingSkill() {
        let s = session("s1", days: [
            day("2026-09-10", cost: 10, skills: [("dataviz", 5), ("deleted-skill", 5)]),
        ])
        let r = AttributionEngine.aggregate(sessions: [s], skills: [skillEntry("dataviz")])
        XCTAssertEqual(r.skills.first(where: { $0.skill == "dataviz" })?.isInstalled, true)
        XCTAssertEqual(r.skills.first(where: { $0.skill == "deleted-skill" })?.isInstalled, false)
    }

    func testMatchSkillAcceptsBothTagForms() {
        let entry = skillEntry("frontend-design")
        XCTAssertTrue(AttributionEngine.matchSkill("frontend-design", to: entry))
        XCTAssertTrue(AttributionEngine.matchSkill("frontend-design:frontend-design", to: entry))
        XCTAssertFalse(AttributionEngine.matchSkill("dataviz", to: entry))
    }

    // MARK: - Independence and remainders

    /// The corpus case: one record carrying both tags counts fully under each
    /// dimension, so the two attributed sums can exceed the total while each
    /// remainder is still computed against that same total.
    func testTwoRemaindersAreComputedIndependently() {
        let s = session("s1", days: [
            day("2026-09-10", cost: 10, skills: [("ship", 8)], mcps: [("srv", "fetch", 6)]),
        ])
        let r = AttributionEngine.aggregate(sessions: [s])

        XCTAssertEqual(r.totalCost, 10, accuracy: 1e-9)
        XCTAssertEqual(r.skillAttributedCost, 8, accuracy: 1e-9)
        XCTAssertEqual(r.mcpAttributedCost, 6, accuracy: 1e-9)
        XCTAssertEqual(r.skillUnattributedCost, 2, accuracy: 1e-9)
        XCTAssertEqual(r.mcpUnattributedCost, 4, accuracy: 1e-9)
        XCTAssertGreaterThan(r.skillAttributedCost + r.mcpAttributedCost, r.totalCost)
        XCTAssertEqual(r.skillCoverage, 0.8, accuracy: 1e-9)
    }

    /// Floating-point drift must not surface as a negative remainder.
    func testRemainderClampsAtZero() {
        let s = session("s1", days: [day("2026-09-10", cost: 0.1, skills: [("ship", 0.1 + 1e-17)])])
        let r = AttributionEngine.aggregate(sessions: [s])
        XCTAssertGreaterThanOrEqual(r.skillUnattributedCost, 0)
    }

    func testCoverageIsZeroWhenNothingIsBilled() {
        let r = AttributionEngine.aggregate(sessions: [])
        XCTAssertEqual(r.skillCoverage, 0)
        XCTAssertEqual(r.mcpCoverage, 0)
        XCTAssertTrue(r.isEmpty)
    }

    /// A corpus written before Claude Code 2.1.24x has billed cost but no tags.
    /// The rollup must report that as empty-with-spend, so the UI can say
    /// "no attribution data" rather than implying nothing was spent.
    func testUntaggedCorpusIsEmptyButRetainsTotalCost() {
        let s = session("s1", days: [day("2026-09-10", cost: 42)])
        let r = AttributionEngine.aggregate(sessions: [s])
        XCTAssertTrue(r.isEmpty)
        XCTAssertEqual(r.totalCost, 42, accuracy: 1e-9)
        XCTAssertEqual(r.skillUnattributedCost, 42, accuracy: 1e-9)
    }

    // MARK: - Aggregation across sessions

    func testSessionCountCountsDistinctSessionsNotDays() {
        let a = session("s1", days: [
            day("2026-09-10", cost: 5, skills: [("ship", 5)]),
            day("2026-09-11", cost: 5, skills: [("ship", 5)]),
        ])
        let b = session("s2", days: [day("2026-09-10", cost: 5, skills: [("ship", 5)])])
        let r = AttributionEngine.aggregate(sessions: [a, b])
        let row = r.skills.first
        XCTAssertEqual(row?.sessionCount, 2, "two days of one session is still one session")
        XCTAssertEqual(row?.turnCount, 3)
        XCTAssertEqual(row?.estimatedCost ?? 0, 15, accuracy: 1e-9)
    }

    func testMcpRowsKeepServerAndToolSeparate() {
        let s = session("s1", days: [
            day("2026-09-10", cost: 10, mcps: [("srv-a", "fetch", 3), ("srv-b", "fetch", 4)]),
        ])
        let r = AttributionEngine.aggregate(sessions: [s])
        XCTAssertEqual(r.mcps.count, 2, "same tool name on two servers must not merge")
        XCTAssertEqual(r.mcps.map(\.id).sorted(), ["srv-a/fetch", "srv-b/fetch"])
    }

    // MARK: - Agents

    func testAgentSpendFoldsWholeSubagentSessions() {
        let a = session("sub1", days: [day("2026-09-10", cost: 6)], agent: "Explore", isSubagent: true)
        let b = session("sub2", days: [day("2026-09-10", cost: 4)], agent: "Explore", isSubagent: true)
        let c = session("sub3", days: [day("2026-09-10", cost: 9)], agent: "Plan", isSubagent: true)
        let main = session("main", days: [day("2026-09-10", cost: 1)])

        let r = AttributionEngine.aggregate(sessions: [a, b, c, main])
        XCTAssertEqual(r.agents.count, 2)
        // Explore is 6 + 4 = 10 across two sessions, so it outranks Plan's 9.
        XCTAssertEqual(r.agents.first?.agent, "Explore", "rows sort by cost descending")
        XCTAssertEqual(r.agents.first?.estimatedCost ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(r.agents.first?.sessionCount, 2)
        let plan = r.agents.first { $0.agent == "Plan" }
        XCTAssertEqual(plan?.sessionCount, 1)
        XCTAssertEqual(plan?.estimatedCost ?? 0, 9, accuracy: 1e-9)
    }

    /// Agent spend respects the window too: only the in-range days count.
    func testAgentSpendIsWindowed() {
        let a = session("sub1", days: [
            day("2026-09-01", cost: 6),
            day("2026-09-10", cost: 4),
        ], agent: "Explore", isSubagent: true)
        let r = AttributionEngine.aggregate(sessions: [a], fromDay: "2026-09-05", toDay: "2026-09-30")
        XCTAssertEqual(r.agents.first?.estimatedCost ?? 0, 4, accuracy: 1e-9)
    }

    // MARK: - Ordering

    func testRowsSortByCostThenIdForStability() {
        let s = session("s1", days: [
            day("2026-09-10", cost: 10, skills: [("bbb", 5), ("aaa", 5), ("ccc", 1)]),
        ])
        let r = AttributionEngine.aggregate(sessions: [s])
        XCTAssertEqual(r.skills.map(\.skill), ["aaa", "bbb", "ccc"])
    }
}

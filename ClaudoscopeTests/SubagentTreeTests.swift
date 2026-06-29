import XCTest
@testable import Claudoscope

/// Tests for nested subagent-tree reconstruction (depth-aware) and the
/// agent-id normalization that joins filenames to toolUseResult.agentId.
final class SubagentTreeTests: XCTestCase {

    private func sum(id: String, agentId: String?, spawned: [String]) -> SessionSummary {
        SessionSummary(
            id: id, projectId: "p", slug: nil, title: id,
            firstTimestamp: "", lastTimestamp: "", messageCount: 0, primaryModel: nil,
            totalInputTokens: 0, totalOutputTokens: 0, totalCacheReadTokens: 0,
            totalCacheCreationTokens: 0, totalCacheCreation5mTokens: 0, totalCacheCreation1hTokens: 0,
            compactionCount: 0, estimatedCost: 0, hasError: false, modelBreakdown: [],
            toolCallCount: 0, observability: .empty, isSubagent: true,
            dailyContributions: [], agentId: agentId, spawnedAgentIds: spawned
        )
    }

    func testNormalizeAgentIdStripsPrefixes() {
        XCTAssertEqual(ObservabilityAnalyzer.normalizeAgentId("agent-abc123"), "abc123")
        XCTAssertEqual(ObservabilityAnalyzer.normalizeAgentId("agent-acompact-deadbeef"), "deadbeef")
        XCTAssertEqual(ObservabilityAnalyzer.normalizeAgentId("agent-aside_question-cafe"), "cafe")
        XCTAssertEqual(ObservabilityAnalyzer.normalizeAgentId("bare"), "bare")
    }

    func testNestedTreeDepth2() {
        // root spawns A; A spawns B.
        let parent = sum(id: "root", agentId: nil, spawned: [])
        let a = sum(id: "agent-A", agentId: "A", spawned: ["B"])
        let b = sum(id: "agent-B", agentId: "B", spawned: [])
        let tree = ObservabilityAnalyzer.buildSubagentTree(parentSession: parent, subagentSummaries: [a, b])
        XCTAssertEqual(tree.id, "root")
        XCTAssertEqual(tree.children.map(\.id), ["agent-A"])  // B is nested, not top-level
        XCTAssertEqual(tree.children.first?.children.map(\.id), ["agent-B"])
    }

    func testFlatWhenNoEdges() {
        // No spawnedAgentIds => all subagents become direct children (old behavior).
        let parent = sum(id: "root", agentId: nil, spawned: [])
        let a = sum(id: "agent-A", agentId: "A", spawned: [])
        let b = sum(id: "agent-B", agentId: "B", spawned: [])
        let tree = ObservabilityAnalyzer.buildSubagentTree(parentSession: parent, subagentSummaries: [a, b])
        XCTAssertEqual(Set(tree.children.map(\.id)), ["agent-A", "agent-B"])
        XCTAssertTrue(tree.children.allSatisfy { $0.children.isEmpty })
    }

    func testCycleDoesNotInfiniteLoop() {
        // A spawns B, B spawns A (malformed). Must terminate.
        let parent = sum(id: "root", agentId: nil, spawned: [])
        let a = sum(id: "agent-A", agentId: "A", spawned: ["B"])
        let b = sum(id: "agent-B", agentId: "B", spawned: ["A"])
        let tree = ObservabilityAnalyzer.buildSubagentTree(parentSession: parent, subagentSummaries: [a, b])
        // Both are spawned-by-others, so neither is a root.
        XCTAssertTrue(tree.children.isEmpty)
    }

    func testOrphanSubagentAttachesAtTopLevel() {
        let parent = sum(id: "root", agentId: nil, spawned: [])
        let c = sum(id: "agent-C", agentId: "C", spawned: [])
        let tree = ObservabilityAnalyzer.buildSubagentTree(parentSession: parent, subagentSummaries: [c])
        XCTAssertEqual(tree.children.map(\.id), ["agent-C"])
    }
}

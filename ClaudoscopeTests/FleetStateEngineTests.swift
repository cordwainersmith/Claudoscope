import XCTest
@testable import Claudoscope

final class FleetStateEngineTests: XCTestCase {
    private let now = ISO8601.parse("2026-09-23T12:10:00.000Z")!
    private let threshold: TimeInterval = 60
    private let window: TimeInterval = 24 * 3600

    private func summary(id: String = "s1", last: String = "2026-09-23T12:00:00.000Z",
                         hasError: Bool = false, isSubagent: Bool = false,
                         bypass: Bool? = nil, kind: String? = nil, cowork: Bool = false) -> SessionSummary {
        SessionSummary(
            id: id, projectId: "-Users-x-proj", slug: nil, title: id,
            firstTimestamp: last, lastTimestamp: last, messageCount: 1, primaryModel: nil,
            totalInputTokens: 0, totalOutputTokens: 0, totalCacheReadTokens: 0,
            totalCacheCreationTokens: 0, totalCacheCreation5mTokens: 0,
            totalCacheCreation1hTokens: 0, compactionCount: 0, estimatedCost: 0,
            hasError: hasError, modelBreakdown: [], toolCallCount: 0,
            observability: .empty, isSubagent: isSubagent, dailyContributions: [],
            isCowork: cowork, sessionKind: kind, everBypassedPermissions: bypass
        )
    }

    private func registry(sessionId: String = "s1", status: String, statusAt: Date? = nil,
                          waitingFor: String? = nil, kind: String = "interactive") -> RegistryEntry {
        RegistryEntry(pid: 1, sessionId: sessionId, cwd: "/Users/x/proj-wt", startedAt: 1,
                      kind: kind, status: status,
                      statusUpdatedAt: (statusAt ?? now).timeIntervalSince1970 * 1000,
                      updatedAt: now.timeIntervalSince1970 * 1000, waitingFor: waitingFor)
    }

    private func hook(_ kind: FleetHookEvent.Kind, at: Date, message: String? = nil) -> FleetHookEvent {
        FleetHookEvent(kind: kind, message: message, receivedAt: at, cwd: nil)
    }

    private func derive(_ s: SessionSummary, _ r: RegistryEntry?, _ h: FleetHookEvent?) -> FleetState {
        FleetStateEngine.state(summary: s, registry: r, hookEvent: h, now: now, activeThreshold: threshold).state
    }

    // MARK: precedence

    func testFreshHookBeatsRegistry() {
        let h = hook(.permissionPrompt, at: now.addingTimeInterval(-5))
        XCTAssertEqual(derive(summary(), registry(status: "busy", statusAt: now.addingTimeInterval(-30)), h), .blockedOnPermission)
    }

    func testStopHookIsYourTurn() {
        let h = hook(.yourTurn, at: now.addingTimeInterval(-5))
        XCTAssertEqual(derive(summary(), nil, h), .waitingOnUser(reason: "Finished, ready for review"))
    }

    func testRegistryWaitingBeatsTranscript() {
        let r = registry(status: "waiting", waitingFor: "input needed")
        XCTAssertEqual(derive(summary(last: "2026-09-23T12:09:50.000Z"), r, nil), .waitingOnUser(reason: "input needed"))
    }

    func testRegistryBusyAndIdle() {
        XCTAssertEqual(derive(summary(), registry(status: "busy"), nil), .working)
        XCTAssertEqual(derive(summary(), registry(status: "shell"), nil), .working)
        XCTAssertEqual(derive(summary(), registry(status: "idle"), nil), .idle)
    }

    func testUnknownRegistryStatusIsNeverDone() {
        XCTAssertEqual(derive(summary(last: "2026-09-23T11:00:00.000Z"), registry(status: "mystery"), nil), .idle)
        XCTAssertEqual(derive(summary(last: "2026-09-23T12:09:50.000Z"), registry(status: "mystery"), nil), .working)
    }

    func testTranscriptFallback() {
        XCTAssertEqual(derive(summary(last: "2026-09-23T12:09:30.000Z"), nil, nil), .working)
        XCTAssertEqual(derive(summary(last: "2026-09-23T11:00:00.000Z"), nil, nil), .done)
        XCTAssertEqual(derive(summary(last: "2026-09-23T11:00:00.000Z", hasError: true), nil, nil), .failed)
    }

    // MARK: staleness

    func testHookClearedByNewerTranscriptActivity() {
        let h = hook(.permissionPrompt, at: ISO8601.parse("2026-09-23T11:59:00.000Z")!)
        XCTAssertTrue(FleetStateEngine.hookEventIsStale(h, lastTimestamp: "2026-09-23T12:00:00.000Z", registry: nil))
        XCTAssertEqual(derive(summary(last: "2026-09-23T12:09:30.000Z"), nil, h), .working)
        XCTAssertEqual(derive(summary(), nil, h), .done, "stale hook, 10 minutes quiet, no process")
    }

    func testHookClearedByRegistryBusyAfterIt() {
        let h = hook(.permissionPrompt, at: now.addingTimeInterval(-20))
        let r = registry(status: "busy", statusAt: now.addingTimeInterval(-10))
        XCTAssertTrue(FleetStateEngine.hookEventIsStale(h, lastTimestamp: "2026-09-23T11:00:00.000Z", registry: r))
        XCTAssertEqual(derive(summary(last: "2026-09-23T11:00:00.000Z"), r, h), .working)
    }

    func testHookNotClearedByRegistryIdleAfterIt() {
        let h = hook(.permissionPrompt, at: now.addingTimeInterval(-20))
        let r = registry(status: "idle", statusAt: now.addingTimeInterval(-10))
        XCTAssertFalse(FleetStateEngine.hookEventIsStale(h, lastTimestamp: "2026-09-23T11:00:00.000Z", registry: r))
    }

    // MARK: buildAgents

    func testBuildAgentsWindowSubagentsAndFlags() {
        let sessions = [
            summary(id: "old", last: "2026-09-20T12:00:00.000Z"),
            summary(id: "sub", isSubagent: true),
            summary(id: "live-old", last: "2026-09-20T12:00:00.000Z"),
            summary(id: "bypass", bypass: true),
            summary(id: "bg", kind: "bg"),
        ]
        let reg = [registry(sessionId: "live-old", status: "busy")]
        let agents = FleetStateEngine.buildAgents(
            sessions: sessions, registry: reg, hookEvents: [:], now: now,
            activeThreshold: threshold, recentWindow: window)
        let ids = Set(agents.map(\.id))
        XCTAssertEqual(ids, ["live-old", "bypass", "bg"], "old excluded, subagent excluded, live-old kept via registry")
        XCTAssertTrue(agents.first { $0.id == "live-old" }!.isLive)
        XCTAssertTrue(agents.first { $0.id == "bypass" }!.isBypass)
        XCTAssertTrue(agents.first { $0.id == "bg" }!.isBackgroundJob)
        XCTAssertEqual(agents.first { $0.id == "live-old" }!.focusNeedle, "proj-wt")
        XCTAssertEqual(agents.first { $0.id == "bypass" }!.focusNeedle, "proj")
    }

    func testBackgroundFlagFromRegistryKind() {
        let agents = FleetStateEngine.buildAgents(
            sessions: [summary()], registry: [registry(status: "idle", kind: "bg")], hookEvents: [:],
            now: now, activeThreshold: threshold, recentWindow: window)
        XCTAssertEqual(agents.first?.isBackgroundJob, true)
    }

    func testAttentionQueueOldestFirst() {
        let sessions = [summary(id: "a"), summary(id: "b"), summary(id: "c")]
        let events = [
            "a": hook(.permissionPrompt, at: now.addingTimeInterval(-10)),
            "b": hook(.genericBlock, at: now.addingTimeInterval(-300), message: "Plan approval"),
        ]
        let agents = FleetStateEngine.buildAgents(
            sessions: sessions, registry: [], hookEvents: events, now: now,
            activeThreshold: threshold, recentWindow: window)
        let queue = FleetStateEngine.attentionQueue(agents)
        XCTAssertEqual(queue.map(\.id), ["b", "a"])
        XCTAssertEqual(queue.first?.state, .waitingOnUser(reason: "Plan approval"))
        XCTAssertEqual(agents.map(\.id), ["a", "b", "c"], "board sorts blocked, then waiting, then the rest")
    }

    func testDuplicateRegistryEntriesKeepNewest() {
        let older = RegistryEntry(pid: 2, sessionId: "s1", cwd: "/old", startedAt: 1, status: "idle",
                                  statusUpdatedAt: 1, updatedAt: 1)
        let newer = registry(status: "busy")
        let agents = FleetStateEngine.buildAgents(
            sessions: [summary()], registry: [older, newer], hookEvents: [:],
            now: now, activeThreshold: threshold, recentWindow: window)
        XCTAssertEqual(agents.first?.registry?.pid, 1)
        XCTAssertEqual(agents.first?.state, .working)
    }

    // MARK: hook classification

    func testClassifyHookEvent() {
        XCTAssertEqual(FleetStateEngine.classifyHookEvent(notificationType: "permission_prompt", hookEventName: "Notification", message: nil), .permissionPrompt)
        XCTAssertEqual(FleetStateEngine.classifyHookEvent(notificationType: "elicitation_dialog", hookEventName: "Notification", message: nil), .elicitation)
        XCTAssertNil(FleetStateEngine.classifyHookEvent(notificationType: "idle_prompt", hookEventName: "Notification", message: nil))
        XCTAssertNil(FleetStateEngine.classifyHookEvent(notificationType: "auth_success", hookEventName: "Notification", message: nil))
        XCTAssertEqual(FleetStateEngine.classifyHookEvent(notificationType: nil, hookEventName: "Stop", message: nil), .yourTurn)
        XCTAssertEqual(FleetStateEngine.classifyHookEvent(notificationType: nil, hookEventName: "Notification", message: "Claude needs your permission"), .permissionPrompt)
        XCTAssertEqual(FleetStateEngine.classifyHookEvent(notificationType: "", hookEventName: "Notification", message: "Plan ready"), .genericBlock)
    }
}

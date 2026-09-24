import XCTest
@testable import Claudoscope

final class FleetStateEngineTests: XCTestCase {
    private let now = ISO8601.parse("2026-09-23T12:10:00.000Z")!
    private let threshold: TimeInterval = 60
    private let window: TimeInterval = 24 * 3600

    private func summary(id: String = "s1", last: String = "2026-09-23T12:00:00.000Z",
                         hasError: Bool = false, isSubagent: Bool = false,
                         bypass: Bool? = nil, kind: String? = nil, cowork: Bool = false,
                         project: String = "-Users-x-proj") -> SessionSummary {
        SessionSummary(
            id: id, projectId: project, slug: nil, title: id,
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
                          waitingFor: String? = nil, kind: String = "interactive",
                          name: String? = nil, nameSource: String? = nil) -> RegistryEntry {
        RegistryEntry(pid: 1, sessionId: sessionId, cwd: "/Users/x/proj-wt", startedAt: 1,
                      kind: kind, name: name, nameSource: nameSource, status: status,
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

    // MARK: crash detection

    private func exit(status: String, statusAt: Date? = nil, at: Date) -> RegistryExit {
        RegistryExit(entry: registry(status: status, statusAt: statusAt), at: at)
    }

    func testRegistryExitMidTurnIsFailedWithReason() {
        let s = summary(last: "2026-09-23T12:09:50.000Z")
        let e = exit(status: "busy", statusAt: now.addingTimeInterval(-60), at: now.addingTimeInterval(-5))
        let derived = FleetStateEngine.state(summary: s, registry: nil, hookEvent: nil, exit: e,
                                             now: now, activeThreshold: threshold)
        XCTAssertEqual(derived.state, .failed, "exit beats transcript-recency Working")
        XCTAssertEqual(derived.since, e.at)
        XCTAssertEqual(derived.failureReason, "Process exited mid-turn")
    }

    func testRegistryExitAfterStopHookIsNotFailure() {
        let e = exit(status: "busy", statusAt: now.addingTimeInterval(-60), at: now.addingTimeInterval(-5))
        let h = hook(.yourTurn, at: now.addingTimeInterval(-30))
        XCTAssertFalse(FleetStateEngine.exitedMidTurn(e, hookEvent: h, lastTimestamp: "2026-09-23T12:00:00.000Z"))
        let derived = FleetStateEngine.state(summary: summary(), registry: nil, hookEvent: h, exit: e,
                                             now: now, activeThreshold: threshold)
        XCTAssertNotEqual(derived.state, .failed)
        XCTAssertNil(derived.failureReason)
    }

    func testRegistryExitClearedByTranscriptActivity() {
        let e = exit(status: "busy", at: now.addingTimeInterval(-30))
        XCTAssertFalse(FleetStateEngine.exitedMidTurn(e, hookEvent: nil, lastTimestamp: "2026-09-23T12:09:50.000Z"))
        let derived = FleetStateEngine.state(summary: summary(last: "2026-09-23T12:09:50.000Z"), registry: nil,
                                             hookEvent: nil, exit: e, now: now, activeThreshold: threshold)
        XCTAssertEqual(derived.state, .working)
    }

    func testRegistryExitIgnoredWhenIdle() {
        let e = exit(status: "idle", at: now.addingTimeInterval(-5))
        XCTAssertFalse(FleetStateEngine.exitedMidTurn(e, hookEvent: nil, lastTimestamp: "2026-09-23T12:00:00.000Z"))
        XCTAssertEqual(FleetStateEngine.state(summary: summary(), registry: nil, hookEvent: nil, exit: e,
                                              now: now, activeThreshold: threshold).state, .done)
    }

    func testBuildAgentsCarriesFailureReason() {
        let agents = FleetStateEngine.buildAgents(
            sessions: [summary(id: "s1"), summary(id: "s2")], registry: [], hookEvents: [:],
            exits: ["s1": exit(status: "shell", at: now.addingTimeInterval(-5))],
            now: now, activeThreshold: threshold, recentWindow: window)
        XCTAssertEqual(agents.first { $0.id == "s1" }?.state, .failed)
        XCTAssertEqual(agents.first { $0.id == "s1" }?.failureReason, "Process exited mid-turn")
        XCTAssertNil(agents.first { $0.id == "s2" }?.failureReason)
    }

    // MARK: periodic refresh

    func testNeedsPeriodicRefreshForNonLiveWorking() {
        let build: ([SessionSummary], [RegistryEntry]) -> [FleetAgent] = { sessions, reg in
            FleetStateEngine.buildAgents(sessions: sessions, registry: reg, hookEvents: [:], now: self.now,
                                         activeThreshold: self.threshold, recentWindow: self.window)
        }
        XCTAssertTrue(FleetStateEngine.needsPeriodicRefresh(build([summary(last: "2026-09-23T12:09:30.000Z")], [])))
        XCTAssertFalse(FleetStateEngine.needsPeriodicRefresh(build([summary(last: "2026-09-23T12:00:00.000Z")], [])))
        XCTAssertFalse(FleetStateEngine.needsPeriodicRefresh(build([summary()], [registry(status: "busy")])))
    }

    func testNeedsPeriodicRefreshForAttentionAgents() {
        let agents = FleetStateEngine.buildAgents(
            sessions: [summary()], registry: [registry(status: "waiting")], hookEvents: [:],
            now: now, activeThreshold: threshold, recentWindow: window)
        XCTAssertTrue(FleetStateEngine.needsPeriodicRefresh(agents))
    }

    func testNonLiveWorkingBecomesDoneAfterThreshold() {
        let s = summary(last: "2026-09-23T12:10:00.000Z")
        XCTAssertEqual(FleetStateEngine.state(summary: s, registry: nil, hookEvent: nil, now: now,
                                              activeThreshold: threshold).state, .working)
        XCTAssertEqual(FleetStateEngine.state(summary: s, registry: nil, hookEvent: nil, now: now.addingTimeInterval(61),
                                              activeThreshold: threshold).state, .done)
    }

    // MARK: registry name

    func testDisplayNameFromRegistry() {
        func agent(_ r: RegistryEntry?) -> FleetAgent? {
            FleetStateEngine.buildAgents(sessions: [summary()], registry: r.map { [$0] } ?? [], hookEvents: [:],
                                         now: now, activeThreshold: threshold, recentWindow: window).first
        }
        XCTAssertEqual(agent(registry(status: "idle", name: "fix-gauge", nameSource: "auto"))?.displayName, "fix-gauge")
        XCTAssertNil(agent(registry(status: "idle", name: "", nameSource: "auto"))?.displayName)
        XCTAssertNil(agent(registry(status: "idle", name: "proj-9b", nameSource: "derived"))?.displayName)
        XCTAssertNil(agent(nil)?.displayName)
    }

    // MARK: grouping

    func testGroupedByProjectSortsByNameKeepsOrder() {
        func s(_ id: String, _ project: String) -> SessionSummary { summary(id: id, project: project) }
        let agents = FleetStateEngine.buildAgents(
            sessions: [s("a", "-Users-x-zeta"), s("b", "-Users-x-Alpha"), s("c", "-Users-x-zeta")],
            registry: [], hookEvents: [:], now: now, activeThreshold: threshold, recentWindow: window)
        let groups = FleetStateEngine.groupedByProject(agents)
        XCTAssertEqual(groups.map(\.project), ["Alpha", "zeta"])
        XCTAssertEqual(groups.last?.agents.map(\.id), agents.filter { $0.projectName == "zeta" }.map(\.id))
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

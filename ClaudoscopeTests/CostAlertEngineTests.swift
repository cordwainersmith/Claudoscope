import XCTest
@testable import Claudoscope

/// Unit tests for the pure cost-alert engine, the intraday spend ledger, and
/// the SessionStore folds that feed them. Alerts interrupt the user, so the
/// doubling ladder, episode reset, and rebaseline rules must be exact.
final class CostAlertEngineTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    private func minutes(_ m: Double) -> TimeInterval { m * 60 }

    private func config(
        master: Bool = true,
        session: CostAlertRule = CostAlertRule(enabled: false, threshold: 5, unit: .dollars),
        rolling: CostAlertRule = CostAlertRule(enabled: false, threshold: 10, unit: .dollars),
        rollingWindowMinutes: Int = 60,
        daily: CostAlertRule = CostAlertRule(enabled: false, threshold: 25, unit: .dollars),
        monthly: CostAlertRule = CostAlertRule(enabled: false, threshold: 200, unit: .dollars)
    ) -> CostAlertConfig {
        CostAlertConfig(
            masterEnabled: master,
            session: session,
            rolling: rolling,
            rollingWindowMinutes: rollingWindowMinutes,
            daily: daily,
            monthly: monthly
        )
    }

    private func snapshot(
        recentSessions: [CostSessionFigure] = [],
        todayCost: Double = 0,
        todayTokens: Int = 0,
        monthCost: Double = 0,
        monthTokens: Int = 0,
        dayKey: String = "2026-07-12",
        monthKey: String = "2026-07"
    ) -> CostSnapshot {
        CostSnapshot(
            cumulativeCost: 0,
            cumulativeTokens: 0,
            recentSessions: recentSessions,
            todayCost: todayCost,
            todayTokens: todayTokens,
            monthCost: monthCost,
            monthTokens: monthTokens,
            dayKey: dayKey,
            monthKey: monthKey
        )
    }

    private func evaluate(
        _ config: CostAlertConfig,
        _ snap: CostSnapshot,
        rollingCost: Double = 0,
        rollingTokens: Int = 0,
        state: CostAlertFiredState = CostAlertFiredState()
    ) -> (events: [CostAlertEvent], state: CostAlertFiredState) {
        CostAlertEngine.evaluate(
            config: config,
            snapshot: snap,
            rollingCost: rollingCost,
            rollingTokens: rollingTokens,
            state: state
        )
    }

    // MARK: - Session cap

    func testSessionCapFiresOnceThenStaysQuiet() {
        let cfg = config(session: CostAlertRule(enabled: true, threshold: 5, unit: .dollars))
        let snap = snapshot(recentSessions: [CostSessionFigure(id: "s1", title: "Fix auth", cost: 6.2, tokens: 0)])

        let first = evaluate(cfg, snap)
        XCTAssertEqual(first.events.count, 1)
        XCTAssertEqual(first.events[0].kind, .session)
        XCTAssertEqual(first.events[0].scopeId, "s1")
        XCTAssertEqual(first.events[0].level, 0)
        XCTAssertEqual(first.events[0].effectiveThreshold, 5)
        XCTAssertEqual(first.events[0].measured, 6.2)

        let second = evaluate(cfg, snap, state: first.state)
        XCTAssertTrue(second.events.isEmpty, "same figure must not re-fire")
    }

    func testSessionCapRefiresAtDoubling() {
        let cfg = config(session: CostAlertRule(enabled: true, threshold: 5, unit: .dollars))
        var state = evaluate(cfg, snapshot(recentSessions: [CostSessionFigure(id: "s1", title: "T", cost: 6, tokens: 0)])).state

        let below = evaluate(cfg, snapshot(recentSessions: [CostSessionFigure(id: "s1", title: "T", cost: 9.9, tokens: 0)]), state: state)
        XCTAssertTrue(below.events.isEmpty, "9.9 has not reached the 2x threshold of 10")
        state = below.state

        let doubled = evaluate(cfg, snapshot(recentSessions: [CostSessionFigure(id: "s1", title: "T", cost: 10, tokens: 0)]), state: state)
        XCTAssertEqual(doubled.events.count, 1)
        XCTAssertEqual(doubled.events[0].level, 1)
        XCTAssertEqual(doubled.events[0].effectiveThreshold, 10)
    }

    func testJumpAcrossDoublingsEmitsSingleHighestEvent() {
        let cfg = config(session: CostAlertRule(enabled: true, threshold: 5, unit: .dollars))
        let jump = evaluate(cfg, snapshot(recentSessions: [CostSessionFigure(id: "s1", title: "T", cost: 27, tokens: 0)]))

        XCTAssertEqual(jump.events.count, 1, "crossing 5, 10, and 20 at once must produce one event")
        XCTAssertEqual(jump.events[0].level, 2)
        XCTAssertEqual(jump.events[0].effectiveThreshold, 20)

        let below = evaluate(cfg, snapshot(recentSessions: [CostSessionFigure(id: "s1", title: "T", cost: 39.9, tokens: 0)]), state: jump.state)
        XCTAssertTrue(below.events.isEmpty)
        let next = evaluate(cfg, snapshot(recentSessions: [CostSessionFigure(id: "s1", title: "T", cost: 40, tokens: 0)]), state: below.state)
        XCTAssertEqual(next.events.map(\.level), [3], "next fire is the 8x doubling")
    }

    func testTwoRunawaySessionsEachAlert() {
        let cfg = config(session: CostAlertRule(enabled: true, threshold: 5, unit: .dollars))
        let snap = snapshot(recentSessions: [
            CostSessionFigure(id: "a", title: "A", cost: 6, tokens: 0),
            CostSessionFigure(id: "b", title: "B", cost: 7, tokens: 0),
        ])
        let result = evaluate(cfg, snap)
        XCTAssertEqual(result.events.map(\.scopeId).sorted(), ["a", "b"])
    }

    func testTokenUnitUsesTokens() {
        let cfg = config(session: CostAlertRule(enabled: true, threshold: 100_000, unit: .tokens))
        let snap = snapshot(recentSessions: [CostSessionFigure(id: "s1", title: "T", cost: 0.01, tokens: 120_000)])
        let result = evaluate(cfg, snap)
        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events[0].measured, 120_000)
        XCTAssertEqual(result.events[0].unit, .tokens)
    }

    // MARK: - Rolling window

    func testRollingFiresAndEpisodeResetRearms() {
        let cfg = config(rolling: CostAlertRule(enabled: true, threshold: 10, unit: .dollars))

        let fired = evaluate(cfg, snapshot(), rollingCost: 12)
        XCTAssertEqual(fired.events.map(\.kind), [.rolling])
        XCTAssertEqual(fired.events[0].level, 0)

        let still = evaluate(cfg, snapshot(), rollingCost: 13, state: fired.state)
        XCTAssertTrue(still.events.isEmpty, "13 is below the 2x threshold of 20")

        let drained = evaluate(cfg, snapshot(), rollingCost: 4, state: still.state)
        XCTAssertTrue(drained.events.isEmpty)
        XCTAssertEqual(drained.state.rollingLevel, 0, "dropping below the threshold ends the episode")

        let again = evaluate(cfg, snapshot(), rollingCost: 11, state: drained.state)
        XCTAssertEqual(again.events.map(\.level), [0], "a new episode fires at the base threshold again")
    }

    // MARK: - Daily and monthly caps

    func testDailyCapFiresAndRolloverResets() {
        let cfg = config(daily: CostAlertRule(enabled: true, threshold: 25, unit: .dollars))

        let fired = evaluate(cfg, snapshot(todayCost: 30, dayKey: "2026-07-12"))
        XCTAssertEqual(fired.events.map(\.kind), [.daily])

        let quiet = evaluate(cfg, snapshot(todayCost: 31, dayKey: "2026-07-12"), state: fired.state)
        XCTAssertTrue(quiet.events.isEmpty)

        let nextDay = evaluate(cfg, snapshot(todayCost: 26, dayKey: "2026-07-13"), state: quiet.state)
        XCTAssertEqual(nextDay.events.map(\.level), [0], "a new day starts a fresh ladder")
        XCTAssertEqual(nextDay.state.dailyKey, "2026-07-13")
    }

    func testMonthlyCapFiresAndRolloverResets() {
        let cfg = config(monthly: CostAlertRule(enabled: true, threshold: 200, unit: .dollars))

        let fired = evaluate(cfg, snapshot(monthCost: 210, monthKey: "2026-07"))
        XCTAssertEqual(fired.events.map(\.kind), [.monthly])

        let nextMonth = evaluate(cfg, snapshot(monthCost: 205, monthKey: "2026-08"), state: fired.state)
        XCTAssertEqual(nextMonth.events.map(\.level), [0])
        XCTAssertEqual(nextMonth.state.monthlyKey, "2026-08")
    }

    // MARK: - Disabled and degenerate configs

    func testMasterDisabledEmitsNothingAndKeepsState() {
        let cfg = config(
            master: false,
            session: CostAlertRule(enabled: true, threshold: 5, unit: .dollars),
            daily: CostAlertRule(enabled: true, threshold: 25, unit: .dollars)
        )
        let snap = snapshot(
            recentSessions: [CostSessionFigure(id: "s1", title: "T", cost: 100, tokens: 0)],
            todayCost: 100
        )
        var state = CostAlertFiredState()
        state.dailyKey = "old"
        let result = evaluate(cfg, snap, state: state)
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.state, state)
    }

    func testRuleDisabledEmitsNothing() {
        let cfg = config(session: CostAlertRule(enabled: false, threshold: 5, unit: .dollars))
        let snap = snapshot(recentSessions: [CostSessionFigure(id: "s1", title: "T", cost: 100, tokens: 0)])
        XCTAssertTrue(evaluate(cfg, snap).events.isEmpty)
    }

    func testNonPositiveThresholdNeverFires() {
        for threshold in [0.0, -5.0] {
            let cfg = config(session: CostAlertRule(enabled: true, threshold: threshold, unit: .dollars))
            let snap = snapshot(recentSessions: [CostSessionFigure(id: "s1", title: "T", cost: 100, tokens: 0)])
            XCTAssertTrue(evaluate(cfg, snap).events.isEmpty, "threshold \(threshold) must be inert")
        }
    }

    // MARK: - Fired state

    func testSessionLevelCapDropsOldest() {
        var state = CostAlertFiredState()
        for i in 0..<210 {
            state.setSessionLevel(1, for: "s\(i)")
        }
        XCTAssertEqual(state.sessionLevels.count, CostAlertFiredState.sessionLevelCap)
        XCTAssertEqual(state.sessionLevel(for: "s0"), 0, "oldest entry dropped, reads as unfired")
        XCTAssertEqual(state.sessionLevel(for: "s209"), 1)
    }

    // MARK: - Spend ledger

    func testLedgerFirstObservationBaselinesSilently() {
        var ledger = SpendLedger()
        ledger.observe(totalCost: 100, totalTokens: 1_000, at: t0)
        let window = ledger.windowTotals(minutes: 240, at: t0)
        XCTAssertEqual(window.cost, 0)
        XCTAssertEqual(window.tokens, 0)
    }

    func testLedgerAccumulatesDeltasInsideWindowOnly() {
        var ledger = SpendLedger()
        ledger.observe(totalCost: 100, totalTokens: 0, at: t0)
        ledger.observe(totalCost: 103, totalTokens: 0, at: t0.addingTimeInterval(minutes(5)))
        ledger.observe(totalCost: 104.5, totalTokens: 0, at: t0.addingTimeInterval(minutes(65)))

        let hour = ledger.windowTotals(minutes: 60, at: t0.addingTimeInterval(minutes(70)))
        XCTAssertEqual(hour.cost, 1.5, accuracy: 0.0001, "the delta at +5min is outside the last hour")

        let all = ledger.windowTotals(minutes: 240, at: t0.addingTimeInterval(minutes(70)))
        XCTAssertEqual(all.cost, 4.5, accuracy: 0.0001)
    }

    func testLedgerRebaselinesOnDecrease() {
        var ledger = SpendLedger()
        ledger.observe(totalCost: 100, totalTokens: 100, at: t0)
        ledger.observe(totalCost: 90, totalTokens: 90, at: t0.addingTimeInterval(minutes(1)))
        ledger.observe(totalCost: 95, totalTokens: 95, at: t0.addingTimeInterval(minutes(2)))

        let window = ledger.windowTotals(minutes: 60, at: t0.addingTimeInterval(minutes(2)))
        XCTAssertEqual(window.cost, 5, accuracy: 0.0001, "only growth from the new baseline counts")
        XCTAssertEqual(window.tokens, 5)
    }

    func testLedgerExplicitRebaselineSkipsDelta() {
        var ledger = SpendLedger()
        ledger.observe(totalCost: 100, totalTokens: 0, at: t0)
        ledger.observe(totalCost: 150, totalTokens: 0, at: t0.addingTimeInterval(minutes(1)), rebaseline: true)
        ledger.observe(totalCost: 152, totalTokens: 0, at: t0.addingTimeInterval(minutes(2)))

        let window = ledger.windowTotals(minutes: 60, at: t0.addingTimeInterval(minutes(2)))
        XCTAssertEqual(window.cost, 2, accuracy: 0.0001, "the flagged jump must not enter the window")
    }

    func testLedgerPrunesEntriesBeyondMaxWindow() {
        var ledger = SpendLedger()
        ledger.observe(totalCost: 100, totalTokens: 0, at: t0)
        ledger.observe(totalCost: 101, totalTokens: 0, at: t0.addingTimeInterval(minutes(1)))
        ledger.observe(totalCost: 102, totalTokens: 0, at: t0.addingTimeInterval(minutes(300)))

        XCTAssertEqual(ledger.entries.count, 1, "the +1min entry is older than the 240min max window")
        XCTAssertEqual(ledger.entries[0].cost, 1, accuracy: 0.0001)
    }

    func testLedgerTokenOnlyGrowthStillRecords() {
        var ledger = SpendLedger()
        ledger.observe(totalCost: 100, totalTokens: 100, at: t0)
        ledger.observe(totalCost: 100, totalTokens: 250, at: t0.addingTimeInterval(minutes(1)))

        let window = ledger.windowTotals(minutes: 60, at: t0.addingTimeInterval(minutes(1)))
        XCTAssertEqual(window.cost, 0, accuracy: 0.0001)
        XCTAssertEqual(window.tokens, 150, "unknown-model records price to $0 but still spend tokens")
    }

    // MARK: - SessionStore folds feeding the snapshot

    private func day(_ date: String, cost: Double, input: Int = 0, output: Int = 0) -> DailyContribution {
        DailyContribution(
            date: date,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            cacheCreation5mTokens: 0,
            cacheCreation1hTokens: 0,
            estimatedCost: cost,
            modelBreakdown: []
        )
    }

    private func summary(
        id: String,
        title: String = "T",
        cost: Double = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        lastTimestamp: String = "",
        isSubagent: Bool = false,
        days: [DailyContribution] = []
    ) -> SessionSummary {
        SessionSummary(
            id: id, projectId: "p", slug: nil, title: title,
            firstTimestamp: "", lastTimestamp: lastTimestamp, messageCount: 1, primaryModel: nil,
            totalInputTokens: inputTokens, totalOutputTokens: outputTokens, totalCacheReadTokens: 0,
            totalCacheCreationTokens: 0, totalCacheCreation5mTokens: 0, totalCacheCreation1hTokens: 0,
            compactionCount: 0, estimatedCost: cost, hasError: false, modelBreakdown: [],
            toolCallCount: 0, observability: .empty, isSubagent: isSubagent,
            dailyContributions: days
        )
    }

    func testMonthTotalsFoldsOnlyMatchingMonth() {
        let sessions = [
            summary(id: "a", days: [
                day("2026-06-30", cost: 2, input: 5, output: 5),
                day("2026-07-01", cost: 3, input: 10, output: 0),
                day("2026-07-15", cost: 4, input: 10, output: 10),
            ]),
            summary(id: "b", days: [day("2026-08-01", cost: 9, input: 100, output: 0)]),
        ]
        let totals = SessionStore.monthTotals(sessions: sessions, monthKey: "2026-07")
        XCTAssertEqual(totals.cost, 7, accuracy: 0.0001)
        XCTAssertEqual(totals.tokens, 30)
    }

    func testRecentSessionFiguresFiltersSubagentsAndStale() {
        let now = t0
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fresh = iso.string(from: now.addingTimeInterval(-minutes(10)))
        let stale = iso.string(from: now.addingTimeInterval(-minutes(40)))

        let sessions = [
            summary(id: "fresh", title: "Fresh", cost: 3, inputTokens: 100, outputTokens: 50, lastTimestamp: fresh),
            summary(id: "sub", cost: 9, lastTimestamp: fresh, isSubagent: true),
            summary(id: "stale", cost: 9, lastTimestamp: stale),
            summary(id: "no-ts", cost: 9, lastTimestamp: ""),
        ]
        let figures = SessionStore.recentSessionFigures(sessions: sessions, now: now)
        XCTAssertEqual(figures.map(\.id), ["fresh"])
        XCTAssertEqual(figures[0].title, "Fresh")
        XCTAssertEqual(figures[0].cost, 3)
        XCTAssertEqual(figures[0].tokens, 150, "tokens are input + output, matching todayTokens")
    }
}

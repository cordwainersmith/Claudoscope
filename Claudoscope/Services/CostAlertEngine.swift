import Foundation

// MARK: - Spend Ledger

/// Intraday spend deltas, needed because stored cost granularity is one bucket
/// per day. Fed cumulative totals on every evaluation; a drop in either total
/// (rescan, pricing switch, deleted files) rebaselines silently so no phantom
/// delta enters the rolling window.
struct SpendLedgerEntry: Sendable {
    let date: Date
    let cost: Double
    let tokens: Int
}

struct SpendLedger: Sendable {
    private(set) var entries: [SpendLedgerEntry] = []
    private var lastCost: Double?
    private var lastTokens: Int = 0

    static let maxWindowMinutes = 240

    mutating func observe(totalCost: Double, totalTokens: Int, at now: Date, rebaseline: Bool = false) {
        defer { prune(before: now.addingTimeInterval(-Double(Self.maxWindowMinutes) * 60)) }

        guard !rebaseline, let lastCost else {
            self.lastCost = totalCost
            self.lastTokens = totalTokens
            return
        }
        guard totalCost >= lastCost, totalTokens >= lastTokens else {
            self.lastCost = totalCost
            self.lastTokens = totalTokens
            return
        }

        let deltaCost = totalCost - lastCost
        let deltaTokens = totalTokens - lastTokens
        if deltaCost > 0 || deltaTokens > 0 {
            entries.append(SpendLedgerEntry(date: now, cost: deltaCost, tokens: deltaTokens))
        }
        self.lastCost = totalCost
        self.lastTokens = totalTokens
    }

    func windowTotals(minutes: Int, at now: Date) -> (cost: Double, tokens: Int) {
        let cutoff = now.addingTimeInterval(-Double(minutes) * 60)
        var cost = 0.0
        var tokens = 0
        for entry in entries where entry.date >= cutoff {
            cost += entry.cost
            tokens += entry.tokens
        }
        return (cost, tokens)
    }

    private mutating func prune(before cutoff: Date) {
        if let firstKept = entries.firstIndex(where: { $0.date >= cutoff }) {
            entries.removeFirst(firstKept)
        } else {
            entries.removeAll()
        }
    }
}

// MARK: - Engine

/// Pure threshold evaluation. Re-alerts at doublings: with a fired count of n,
/// the next alert fires when the measured value reaches threshold * 2^n. One
/// event max per scope per evaluation (the highest level crossed), so a jump
/// across several doublings produces a single alert.
enum CostAlertEngine {

    static func evaluate(
        config: CostAlertConfig,
        snapshot: CostSnapshot,
        rollingCost: Double,
        rollingTokens: Int,
        state: CostAlertFiredState
    ) -> (events: [CostAlertEvent], state: CostAlertFiredState) {
        guard config.masterEnabled else { return ([], state) }

        var newState = state
        var events: [CostAlertEvent] = []

        if config.session.enabled {
            for figure in snapshot.recentSessions {
                let measured = config.session.unit == .dollars ? figure.cost : Double(figure.tokens)
                let fired = newState.sessionLevel(for: figure.id)
                if let newFired = crossedCount(measured: measured, threshold: config.session.threshold, fired: fired) {
                    newState.setSessionLevel(newFired, for: figure.id)
                    events.append(CostAlertEvent(
                        kind: .session,
                        scopeId: figure.id,
                        scopeTitle: figure.title,
                        unit: config.session.unit,
                        measured: measured,
                        effectiveThreshold: config.session.threshold * pow(2, Double(newFired - 1)),
                        level: newFired - 1
                    ))
                }
            }
        }

        if config.rolling.enabled {
            let measured = config.rolling.unit == .dollars ? rollingCost : Double(rollingTokens)
            if config.rolling.threshold > 0, measured < config.rolling.threshold {
                newState.rollingLevel = 0
            } else if let newFired = crossedCount(measured: measured, threshold: config.rolling.threshold, fired: newState.rollingLevel) {
                newState.rollingLevel = newFired
                events.append(CostAlertEvent(
                    kind: .rolling,
                    scopeId: "rolling",
                    scopeTitle: CostAlertConfig.windowPhrase(minutes: config.rollingWindowMinutes),
                    unit: config.rolling.unit,
                    measured: measured,
                    effectiveThreshold: config.rolling.threshold * pow(2, Double(newFired - 1)),
                    level: newFired - 1
                ))
            }
        }

        if config.daily.enabled {
            if newState.dailyKey != snapshot.dayKey {
                newState.dailyKey = snapshot.dayKey
                newState.dailyLevel = 0
            }
            let measured = config.daily.unit == .dollars ? snapshot.todayCost : Double(snapshot.todayTokens)
            if let newFired = crossedCount(measured: measured, threshold: config.daily.threshold, fired: newState.dailyLevel) {
                newState.dailyLevel = newFired
                events.append(CostAlertEvent(
                    kind: .daily,
                    scopeId: snapshot.dayKey,
                    scopeTitle: "Today",
                    unit: config.daily.unit,
                    measured: measured,
                    effectiveThreshold: config.daily.threshold * pow(2, Double(newFired - 1)),
                    level: newFired - 1
                ))
            }
        }

        if config.monthly.enabled {
            if newState.monthlyKey != snapshot.monthKey {
                newState.monthlyKey = snapshot.monthKey
                newState.monthlyLevel = 0
            }
            let measured = config.monthly.unit == .dollars ? snapshot.monthCost : Double(snapshot.monthTokens)
            if let newFired = crossedCount(measured: measured, threshold: config.monthly.threshold, fired: newState.monthlyLevel) {
                newState.monthlyLevel = newFired
                events.append(CostAlertEvent(
                    kind: .monthly,
                    scopeId: snapshot.monthKey,
                    scopeTitle: "This month",
                    unit: config.monthly.unit,
                    measured: measured,
                    effectiveThreshold: config.monthly.threshold * pow(2, Double(newFired - 1)),
                    level: newFired - 1
                ))
            }
        }

        return (events, newState)
    }

    /// Returns the new fired count if `measured` crossed at least the next
    /// doubling, nil otherwise. Non-positive thresholds never fire.
    private static func crossedCount(measured: Double, threshold: Double, fired: Int) -> Int? {
        guard threshold > 0, measured >= threshold * pow(2, Double(fired)) else { return nil }
        var count = fired
        while count < fired + 64, measured >= threshold * pow(2, Double(count)) {
            count += 1
        }
        return count
    }
}

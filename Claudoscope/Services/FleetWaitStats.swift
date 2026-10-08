import Foundation

/// How long agents waited on the user today, and what answering after the
/// prompt cache expired cost. Pure, so the day filter and pricing are
/// unit-testable.
enum FleetWaitStats {

    struct Summary: Equatable, Sendable {
        let count: Int
        let meanSeconds: TimeInterval
        let maxSeconds: TimeInterval
        let coldRestartCount: Int
        let coldRestartCost: Double
    }

    /// Closed waits that started on the local day `dayKey`; nil when none.
    static func summarize(_ waits: [FleetWaitRecord], dayKey: String,
                          pricingTable: [String: ModelPricing]) -> Summary? {
        let closed = waits.filter { wait in
            wait.endedAt != nil
                && ISO8601.localDayKey(for: Date(timeIntervalSince1970: wait.startedAt)) == dayKey
        }
        guard !closed.isEmpty else { return nil }
        let durations = closed.map { max(0, ($0.endedAt ?? $0.startedAt) - $0.startedAt) }
        let cold = closed.filter(isColdRestart)
        return Summary(
            count: closed.count,
            meanSeconds: durations.reduce(0, +) / Double(durations.count),
            maxSeconds: durations.max() ?? 0,
            coldRestartCount: cold.count,
            coldRestartCost: cold.reduce(0) { $0 + coldRestartCost($1, pricingTable: pricingTable, dayKey: dayKey) }
        )
    }

    /// The wait ended after the cache written by the preceding turn expired.
    static func isColdRestart(_ wait: FleetWaitRecord) -> Bool {
        guard let ended = wait.endedAt, let turn = wait.turnTimestamp, let ttl = wait.cacheTtlSeconds else {
            return false
        }
        return ended > turn + Double(ttl)
    }

    /// Estimate: re-writing the whole context at the cache-write rate of the
    /// tier the session was using.
    static func coldRestartCost(_ wait: FleetWaitRecord, pricingTable: [String: ModelPricing],
                                dayKey: String) -> Double {
        guard let tokens = wait.contextTokens, tokens > 0 else { return 0 }
        let pricing = getModelPricing(wait.model, table: pricingTable, on: dayKey, promptTokens: tokens)
        let rate = wait.cacheTtlSeconds == 3600 ? pricing.cacheCreation1h : pricing.cacheCreation5m
        return Double(tokens) / 1_000_000 * rate
    }
}

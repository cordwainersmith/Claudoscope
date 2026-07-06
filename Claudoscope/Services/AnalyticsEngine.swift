import Foundation

/// Pure computation from [SessionSummary] to AnalyticsData.
/// Port of server/services/analytics-engine.ts
struct AnalyticsEngine {

    /// A session projected onto a date window: only the in-range billed days, with
    /// their token/cost/per-family totals pre-summed. Built once in `compute` and
    /// shared by every aggregator so the windowing pass runs a single time.
    private struct WindowedSession {
        let session: SessionSummary
        let project: Project
        let cost: Double
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheCreationTokens: Int
        let cacheCreation5mTokens: Int
        let cacheCreation1hTokens: Int
        let family: [String: ModelDayCost]   // merged per-family across in-range days
        let days: [DailyContribution]        // in-range days only
        let firstDay: String                 // earliest in-range day
    }

    private static let localDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// LOCAL calendar day (YYYY-MM-DD) for a window bound. Matches the local day
    /// keys the parser stamps on each `DailyContribution`.
    private static func dayKey(_ date: Date) -> String { localDayFormatter.string(from: date) }

    static func compute(
        sessions: [(session: SessionSummary, project: Project)],
        pricingTable: [String: ModelPricing],
        from fromDate: Date? = nil,
        to toDate: Date? = nil
    ) -> AnalyticsData {
        // Window as LOCAL day-string bounds, half-open [fromKey, toKey). Comparing
        // day strings (not reconstructing instants) keeps attribution stable if the
        // machine timezone changes between parse and recompute and avoids DST math.
        // `to` is already an exclusive next-midnight for the custom range, so its day
        // key is the day after the last included day.
        let fromKey = fromDate.map { dayKey($0) }
        let toKey = toDate.map { dayKey($0) }
        func inRange(_ date: String) -> Bool {
            if let fromKey, date < fromKey { return false }
            if let toKey, date >= toKey { return false }
            return true
        }

        var totalSessions = 0
        var totalMessages = 0
        var totalTokens = 0
        var totalCacheTokens = 0
        var totalCost = 0.0

        var dailyMap: [String: DailyUsage] = [:]
        var projectCostMap: [String: ProjectCost] = [:]
        var modelMap: [String: ModelUsage] = [:]
        var windowed: [WindowedSession] = []

        for (session, project) in sessions {
            // Project the session onto the window. A session with no billed day in
            // range contributes to nothing and is dropped (this replaces the old
            // whole-session filter by lastTimestamp, which over-counted /resume).
            let days = session.dailyContributions.filter { inRange($0.date) }
            guard !days.isEmpty else { continue }

            var wInput = 0, wOutput = 0, wCacheRead = 0, wCacheCreate = 0
            var w5m = 0, w1h = 0, wCost = 0.0
            var wFamily: [String: ModelDayCost] = [:]
            var firstDay = days[0].date

            for d in days {
                wInput += d.inputTokens
                wOutput += d.outputTokens
                wCacheRead += d.cacheReadTokens
                wCacheCreate += d.cacheCreationTokens
                w5m += d.cacheCreation5mTokens
                w1h += d.cacheCreation1hTokens
                wCost += d.estimatedCost
                if d.date < firstDay { firstDay = d.date }

                for m in d.modelBreakdown {
                    let p = wFamily[m.model]
                    wFamily[m.model] = ModelDayCost(
                        model: m.model,
                        inputTokens: (p?.inputTokens ?? 0) + m.inputTokens,
                        outputTokens: (p?.outputTokens ?? 0) + m.outputTokens,
                        cacheReadTokens: (p?.cacheReadTokens ?? 0) + m.cacheReadTokens,
                        estimatedCost: (p?.estimatedCost ?? 0) + m.estimatedCost,
                        turnCount: (p?.turnCount ?? 0) + m.turnCount
                    )
                }

                // Daily usage: real per-day data, no proportional splitting.
                var du = dailyMap[d.date] ?? DailyUsage(
                    date: d.date, inputTokens: 0, outputTokens: 0,
                    cacheReadTokens: 0, cacheCreationTokens: 0,
                    cacheCreation5mTokens: 0, cacheCreation1hTokens: 0,
                    sessionCount: 0, messageCount: 0, estimatedCost: 0
                )
                du.inputTokens += d.inputTokens
                du.outputTokens += d.outputTokens
                du.cacheReadTokens += d.cacheReadTokens
                du.cacheCreationTokens += d.cacheCreationTokens
                du.cacheCreation5mTokens += d.cacheCreation5mTokens
                du.cacheCreation1hTokens += d.cacheCreation1hTokens
                du.estimatedCost += d.estimatedCost
                dailyMap[d.date] = du
            }

            // Counts are session-membership-based (a session active in the window
            // counts once, on its earliest in-range day) so per-day counts still sum
            // to the totals. Subagents roll money up but never count as sessions.
            let countsAsSession = !session.isSubagent
            if countsAsSession { totalSessions += 1 }
            totalMessages += session.messageCount
            totalTokens += wInput + wOutput
            totalCacheTokens += wCacheRead + wCacheCreate
            totalCost += wCost

            if var du = dailyMap[firstDay] {
                if countsAsSession { du.sessionCount += 1 }
                du.messageCount += session.messageCount
                dailyMap[firstDay] = du
            }

            let projectSessionDelta = countsAsSession ? 1 : 0
            if var pc = projectCostMap[project.id] {
                pc.totalCost += wCost
                pc.totalTokens += wInput + wOutput
                pc.sessionCount += projectSessionDelta
                pc.messageCount += session.messageCount
                projectCostMap[project.id] = pc
            } else {
                projectCostMap[project.id] = ProjectCost(
                    projectId: project.id,
                    projectName: project.name,
                    totalCost: wCost,
                    totalTokens: wInput + wOutput,
                    sessionCount: projectSessionDelta,
                    messageCount: session.messageCount
                )
            }

            // Model distribution: one count per family the session billed in-range
            // (preserving turnCount = "sessions using this family"); tokens are the
            // windowed per-family totals.
            for (family, fm) in wFamily where family != "unknown" {
                if var mu = modelMap[family] {
                    mu.turnCount += 1
                    mu.totalInputTokens += fm.inputTokens
                    mu.totalOutputTokens += fm.outputTokens
                    modelMap[family] = mu
                } else {
                    modelMap[family] = ModelUsage(
                        model: family,
                        turnCount: 1,
                        totalInputTokens: fm.inputTokens,
                        totalOutputTokens: fm.outputTokens
                    )
                }
            }

            windowed.append(WindowedSession(
                session: session, project: project, cost: wCost,
                inputTokens: wInput, outputTokens: wOutput,
                cacheReadTokens: wCacheRead, cacheCreationTokens: wCacheCreate,
                cacheCreation5mTokens: w5m, cacheCreation1hTokens: w1h,
                family: wFamily, days: days, firstDay: firstDay
            ))
        }

        let dailyUsage = dailyMap.values.sorted { $0.date < $1.date }
        let projectCosts = projectCostMap.values.sorted { $0.totalCost > $1.totalCost }
        let modelUsage = modelMap.values.sorted {
            ($0.totalInputTokens + $0.totalOutputTokens) > ($1.totalInputTokens + $1.totalOutputTokens)
        }

        let cacheAnalytics = computeCacheAnalytics(
            windowed: windowed,
            dailyUsage: dailyUsage,
            pricingTable: pricingTable
        )

        let (modelEfficiency, dailyModelCost) = computeModelAnalytics(
            windowed: windowed,
            totalCost: totalCost
        )

        let latencyAnalytics = computeLatencyAnalytics(windowed: windowed)
        let effortAnalytics = computeEffortAnalytics(windowed: windowed)
        let parallelToolAnalytics = computeParallelToolAnalytics(windowed: windowed)

        return AnalyticsData(
            totalSessions: totalSessions,
            totalMessages: totalMessages,
            totalTokens: totalTokens,
            totalCacheTokens: totalCacheTokens,
            totalCost: totalCost,
            dailyUsage: dailyUsage,
            projectCosts: projectCosts,
            modelUsage: modelUsage,
            cacheAnalytics: cacheAnalytics,
            modelEfficiency: modelEfficiency,
            dailyModelCost: dailyModelCost,
            latencyAnalytics: latencyAnalytics,
            effortAnalytics: effortAnalytics,
            parallelToolAnalytics: parallelToolAnalytics,
            coworkCost: 0,
            coworkHasUnknownModel: false
        )
    }

    // MARK: - Cowork Cost

    /// Aggregate Cowork (Claude desktop) spend across the given sessions, scoped
    /// to `[from, to]` against `effectiveLastActivity`. Returns 0 contribution
    /// for sessions that haven't been parsed yet (no entry in `parsedByID`) or
    /// whose model isn't in the pricing table — those flip `hasUnknownModel`.
    static func computeCoworkCost(
        sessions: [CoworkSession],
        parsedByID: [String: ParsedSession],
        pricingTable: [String: ModelPricing],
        from: Date? = nil,
        to: Date? = nil
    ) -> (cost: Double, hasUnknownModel: Bool) {
        var totalCost = 0.0
        var hasUnknown = false
        for session in sessions {
            if let from, session.effectiveLastActivity < from { continue }
            if let to, session.effectiveLastActivity > to { continue }
            guard let parsed = parsedByID[session.id] else { continue }
            let totals = CoworkStats.totals(records: parsed.records, pricingTable: pricingTable)
            totalCost += totals.cost
            if totals.hasUnknownModel { hasUnknown = true }
        }
        return (totalCost, hasUnknown)
    }

    // MARK: - Cache Analytics

    private static func computeCacheAnalytics(
        windowed: [WindowedSession],
        dailyUsage: [DailyUsage],
        pricingTable: [String: ModelPricing]
    ) -> CacheAnalytics {
        var totalCacheRead = 0
        var totalCacheWrite = 0
        var totalInput = 0
        var totalCache5m = 0
        var totalCache1h = 0
        var actualCost = 0.0
        var hypotheticalUncachedCost = 0.0
        var tierCost5m = 0.0
        var tierCost1h = 0.0

        for w in windowed {
            totalCacheRead += w.cacheReadTokens
            totalCacheWrite += w.cacheCreationTokens
            totalInput += w.inputTokens
            totalCache5m += w.cacheCreation5mTokens
            totalCache1h += w.cacheCreation1hTokens
            actualCost += w.cost

            let pricing = getModelPricing(w.session.primaryModel, table: pricingTable)
            // Hypothetical: if all cache reads were billed at base input price instead
            let cacheReadSavingsPerToken = pricing.input - pricing.cacheRead
            let savings = Double(w.cacheReadTokens) / 1e6 * cacheReadSavingsPerToken
            hypotheticalUncachedCost += w.cost + savings

            // Per-session tier cost reconciles with actualCost; unknown-priced sessions
            // contribute zero on both sides.
            if !pricing.isUnknown {
                tierCost5m += Double(w.cacheCreation5mTokens) / 1e6 * pricing.cacheCreation5m
                tierCost1h += Double(w.cacheCreation1hTokens) / 1e6 * pricing.cacheCreation1h
            }
        }

        let totalCacheTokens = totalCacheRead + totalCacheWrite
        let hitRatio = totalCacheTokens > 0 ? Double(totalCacheRead) / Double(totalCacheTokens) : 0
        // Coverage: share of ALL input-side tokens served from cache (Anthropic's total
        // input = read + write + input). Always <= hitRatio, which omits plain input.
        let coverageDenom = totalCacheTokens + totalInput
        let cacheCoverage = coverageDenom > 0 ? Double(totalCacheRead) / Double(coverageDenom) : 0
        let reuseRate = totalCacheWrite > 0 ? Double(totalCacheRead) / Double(totalCacheWrite) : 0
        let costSavings = hypotheticalUncachedCost - actualCost

        // Daily hit ratio
        let dailyHitRatio = dailyUsage.compactMap { day -> (date: String, ratio: Double)? in
            let total = day.cacheReadTokens + day.cacheCreationTokens
            guard total > 0 else { return nil }
            return (date: day.date, ratio: Double(day.cacheReadTokens) / Double(total))
        }

        let tierCost = CacheTierCost(cost5m: tierCost5m, cost1h: tierCost1h)

        // Per-session cache efficiency leaderboard. Uses each session's lifetime cache
        // figures (a per-session quality metric, not a windowed total). Subagents are
        // skipped — their UUID titles would pollute the leaderboard.
        let sessionEfficiency: [SessionCacheEfficiency] = windowed.compactMap { w in
            let session = w.session
            guard !session.isSubagent else { return nil }
            let readTokens = session.totalCacheReadTokens
            let writeTokens = session.totalCacheCreationTokens
            let total = readTokens + writeTokens
            guard total > 0 else { return nil }
            let ratio = Double(readTokens) / Double(total)
            let pricing = getModelPricing(session.primaryModel, table: pricingTable)
            let savingsPerToken = pricing.input - pricing.cacheRead
            let savings = Double(readTokens) / 1e6 * savingsPerToken
            return SessionCacheEfficiency(
                sessionId: session.id,
                sessionTitle: session.title,
                hitRatio: ratio,
                cacheReadTokens: readTokens,
                cacheWriteTokens: writeTokens,
                savingsAmount: savings,
                primaryModel: session.primaryModel != nil ? getModelFamily(session.primaryModel) : nil
            )
        }.sorted { $0.savingsAmount > $1.savingsAmount }

        // Model-aware cache savings from the windowed per-family cache reads.
        var modelCacheReads: [String: Int] = [:]
        for w in windowed {
            for (family, fm) in w.family {
                modelCacheReads[family, default: 0] += fm.cacheReadTokens
            }
        }
        let modelSavings: [ModelCacheSavings] = modelCacheReads.compactMap { (model, readTokens) in
            guard readTokens > 0, let pricing = pricingTable[model] else { return nil }
            let savingsRate = pricing.input - pricing.cacheRead
            return ModelCacheSavings(
                model: model,
                cacheReadTokens: readTokens,
                savingsPerMTok: savingsRate,
                totalSavings: Double(readTokens) / 1e6 * savingsRate
            )
        }.sorted { $0.totalSavings > $1.totalSavings }

        // Cache busting detection: days where hit ratio drops >30pp from previous day
        var cacheBustingDays: [String] = []
        for i in dailyHitRatio.indices.dropFirst() {
            let drop = dailyHitRatio[i - 1].ratio - dailyHitRatio[i].ratio
            if drop > 0.30 {
                cacheBustingDays.append(dailyHitRatio[i].date)
            }
        }

        return CacheAnalytics(
            hitRatio: hitRatio,
            cacheCoverage: cacheCoverage,
            totalCacheReadTokens: totalCacheRead,
            totalCacheWriteTokens: totalCacheWrite,
            costSavings: costSavings,
            hypotheticalUncachedCost: hypotheticalUncachedCost,
            actualCost: actualCost,
            averageReuseRate: reuseRate,
            dailyHitRatio: dailyHitRatio,
            totalCache5mTokens: totalCache5m,
            totalCache1hTokens: totalCache1h,
            tierCostBreakdown: tierCost,
            sessionEfficiency: sessionEfficiency,
            modelSavings: modelSavings,
            cacheBustingDays: cacheBustingDays
        )
    }

    // MARK: - Model Analytics

    private static func computeModelAnalytics(
        windowed: [WindowedSession],
        totalCost: Double
    ) -> ([ModelEfficiencyRow], [DailyModelCost]) {
        // Aggregate per-family metrics from the windowed breakdowns
        var modelTurns: [String: Int] = [:]
        var modelOutput: [String: Int] = [:]
        var modelCostMap: [String: Double] = [:]

        // Daily model cost, keyed by the real day each amount was billed (fixes the
        // old firstTimestamp keying that dropped resumed spend from a window).
        var dailyModelMap: [String: [String: Double]] = [:] // date -> family -> cost

        for w in windowed {
            for (family, fm) in w.family {
                modelTurns[family, default: 0] += fm.turnCount
                modelOutput[family, default: 0] += fm.outputTokens
                modelCostMap[family, default: 0] += fm.estimatedCost
            }
            for d in w.days {
                for m in d.modelBreakdown {
                    dailyModelMap[d.date, default: [:]][m.model, default: 0] += m.estimatedCost
                }
            }
        }

        let efficiency = modelTurns.keys.map { model in
            let turns = modelTurns[model, default: 0]
            let output = modelOutput[model, default: 0]
            let cost = modelCostMap[model, default: 0]
            return ModelEfficiencyRow(
                model: model,
                turnCount: turns,
                totalOutputTokens: output,
                avgOutputPerTurn: turns > 0 ? output / turns : 0,
                totalCost: cost,
                costPerTurn: turns > 0 ? cost / Double(turns) : 0,
                percentOfTotalCost: totalCost > 0 ? (cost / totalCost) * 100 : 0
            )
        }.sorted { $0.totalCost > $1.totalCost }

        var dailyModelCost: [DailyModelCost] = []
        for (date, models) in dailyModelMap.sorted(by: { $0.key < $1.key }) {
            for (model, cost) in models.sorted(by: { $0.key < $1.key }) {
                dailyModelCost.append(DailyModelCost(date: date, model: model, cost: cost))
            }
        }

        return (efficiency, dailyModelCost)
    }

    static func computeWhatIfSavings(
        sessions: [(session: SessionSummary, project: Project)],
        pricingTable: [String: ModelPricing],
        outputThreshold: Int = 200,
        sourceModel: String = "opus",
        targetModel: String = "sonnet"
    ) -> WhatIfSavings {
        guard pricingTable[sourceModel] != nil,
              pricingTable[targetModel] != nil else {
            return WhatIfSavings(currentCost: 0, hypotheticalCost: 0, savings: 0, savingsPercent: 0, turnsAffected: 0)
        }

        var currentCost = 0.0
        var hypotheticalCost = 0.0
        var turnsAffected = 0

        for (session, _) in sessions {
            for breakdown in session.modelBreakdown {
                currentCost += breakdown.estimatedCost

                if breakdown.model == sourceModel && breakdown.turnCount > 0 {
                    let avgOutput = breakdown.outputTokens / breakdown.turnCount
                    if avgOutput < outputThreshold {
                        // These turns could use the cheaper model
                        turnsAffected += breakdown.turnCount
                        let hypothetical = estimateCostFromTokens(
                            model: "claude-\(targetModel)-4-5",
                            inputTokens: breakdown.inputTokens,
                            outputTokens: breakdown.outputTokens,
                            cacheReadTokens: breakdown.cacheReadTokens,
                            cacheCreation5mTokens: 0,
                            cacheCreation1hTokens: 0,
                            table: pricingTable
                        )
                        hypotheticalCost += hypothetical
                    } else {
                        hypotheticalCost += breakdown.estimatedCost
                    }
                } else {
                    hypotheticalCost += breakdown.estimatedCost
                }
            }
        }

        let savings = currentCost - hypotheticalCost
        let savingsPercent = currentCost > 0 ? (savings / currentCost) * 100 : 0

        return WhatIfSavings(
            currentCost: currentCost,
            hypotheticalCost: hypotheticalCost,
            savings: savings,
            savingsPercent: savingsPercent,
            turnsAffected: turnsAffected
        )
    }

    // MARK: - Latency Analytics

    private static func computeLatencyAnalytics(
        windowed: [WindowedSession]
    ) -> LatencyAnalytics {
        let sessionsWithLatency = windowed.filter { $0.session.observability.medianTurnDurationMs != nil }
        guard !sessionsWithLatency.isEmpty else { return .empty }

        let medians = sessionsWithLatency.compactMap { $0.session.observability.medianTurnDurationMs }.sorted()

        let p50 = percentile(sorted: medians, p: 0.50)
        let p95 = percentile(sorted: medians, p: 0.95)
        let p99 = percentile(sorted: medians, p: 0.99)

        // Histogram buckets by median turn duration
        let bucketRanges: [(label: String, lo: Double, hi: Double)] = [
            ("<1s", 0, 1000),
            ("1-5s", 1000, 5000),
            ("5-10s", 5000, 10000),
            ("10-30s", 10000, 30000),
            ("30-60s", 30000, 60000),
            (">60s", 60000, .infinity)
        ]
        var bucketCounts = [String: Int]()
        for (label, _, _) in bucketRanges { bucketCounts[label] = 0 }
        for median in medians {
            for (label, lo, hi) in bucketRanges {
                if median >= lo && median < hi {
                    bucketCounts[label, default: 0] += 1
                    break
                }
            }
        }
        let histogram = bucketRanges.map { LatencyBucket(label: $0.label, count: bucketCounts[$0.label, default: 0]) }

        // Slowest turns (top 10 by maxTurnDurationMs)
        let slowestTurns: [SlowTurnEntry] = sessionsWithLatency
            .compactMap { pair -> (session: SessionSummary, maxMs: Double)? in
                guard let maxMs = pair.session.observability.maxTurnDurationMs else { return nil }
                return (session: pair.session, maxMs: maxMs)
            }
            .sorted { $0.maxMs > $1.maxMs }
            .prefix(10)
            .enumerated()
            .map { (index, item) in
                SlowTurnEntry(
                    id: "\(item.session.id)-max",
                    sessionId: item.session.id,
                    sessionTitle: item.session.title,
                    turnIndex: index + 1,
                    durationMs: item.maxMs,
                    isPostCompaction: !item.session.observability.compactionTimestamps.isEmpty,
                    model: item.session.primaryModel != nil ? getModelFamily(item.session.primaryModel) : nil
                )
            }

        // Compaction correlation
        let postCompactionSessions = sessionsWithLatency.filter { !$0.session.observability.compactionTimestamps.isEmpty }
        let normalSessions = sessionsWithLatency.filter { $0.session.observability.compactionTimestamps.isEmpty }

        let postCompactionAvgMs: Double = {
            let values = postCompactionSessions.compactMap { $0.session.observability.medianTurnDurationMs }
            guard !values.isEmpty else { return 0 }
            return values.reduce(0, +) / Double(values.count)
        }()

        let normalAvgMs: Double = {
            let values = normalSessions.compactMap { $0.session.observability.medianTurnDurationMs }
            guard !values.isEmpty else { return 0 }
            return values.reduce(0, +) / Double(values.count)
        }()

        // Degrading sessions: any session with a turn exceeding 60s
        let degradingSessionIds = sessionsWithLatency
            .filter { ($0.session.observability.maxTurnDurationMs ?? 0) > 60000 }
            .map { $0.session.id }

        return LatencyAnalytics(
            medianDurationMs: p50,
            p95DurationMs: p95,
            p99DurationMs: p99,
            histogram: histogram,
            slowestTurns: slowestTurns,
            postCompactionAvgMs: postCompactionAvgMs,
            normalAvgMs: normalAvgMs,
            degradingSessionIds: degradingSessionIds
        )
    }

    // MARK: - Effort Analytics

    private static func computeEffortAnalytics(
        windowed: [WindowedSession]
    ) -> EffortAnalytics {
        // Aggregate effort distribution across all sessions
        var totalLow = 0
        var totalMedium = 0
        var totalHigh = 0
        var totalUltrathink = 0

        for w in windowed {
            let dist = w.session.observability.effortDistribution
            totalLow += dist.low
            totalMedium += dist.medium
            totalHigh += dist.high
            totalUltrathink += dist.ultrathink
        }

        let distribution = EffortDistribution(
            low: totalLow,
            medium: totalMedium,
            high: totalHigh,
            ultrathink: totalUltrathink
        )

        // Cost by effort level: group sessions by dominant effort level
        var effortCostMap: [EffortLevel: (turnCount: Int, totalCost: Double)] = [:]
        for w in windowed {
            guard let level = w.session.observability.dominantEffortLevel else { continue }
            var entry = effortCostMap[level, default: (turnCount: 0, totalCost: 0)]
            entry.turnCount += w.session.messageCount
            entry.totalCost += w.cost
            effortCostMap[level] = entry
        }

        let costByEffort: [EffortCostBreakdown] = EffortLevel.allCases.compactMap { level in
            guard let entry = effortCostMap[level], entry.turnCount > 0 else { return nil }
            return EffortCostBreakdown(
                level: level,
                turnCount: entry.turnCount,
                totalCost: entry.totalCost,
                avgCostPerTurn: entry.totalCost / Double(entry.turnCount)
            )
        }

        // Effort over time: group by date
        var dailyEffortMap: [String: (low: Int, medium: Int, high: Int, ultrathink: Int)] = [:]
        for w in windowed {
            // Whole-session effort attributed to its earliest in-range (LOCAL) day,
            // consistent with how sessionCount is attributed.
            let day = w.firstDay
            let dist = w.session.observability.effortDistribution
            var entry = dailyEffortMap[day, default: (low: 0, medium: 0, high: 0, ultrathink: 0)]
            entry.low += dist.low
            entry.medium += dist.medium
            entry.high += dist.high
            entry.ultrathink += dist.ultrathink
            dailyEffortMap[day] = entry
        }

        let effortOverTime: [DailyEffort] = dailyEffortMap.keys.sorted().map { date in
            let entry = dailyEffortMap[date]!
            return DailyEffort(
                date: date,
                distribution: EffortDistribution(
                    low: entry.low,
                    medium: entry.medium,
                    high: entry.high,
                    ultrathink: entry.ultrathink
                )
            )
        }

        return EffortAnalytics(
            distribution: distribution,
            costByEffort: costByEffort,
            effortOverTime: effortOverTime
        )
    }

    // MARK: - Parallel Tool Analytics

    private static func computeParallelToolAnalytics(
        windowed: [WindowedSession]
    ) -> ParallelToolAnalytics {
        var totalParallelGroups = 0
        var maxDegree = 0
        var degreeCounts: [Int: Int] = [:] // maxParallelDegree -> session count

        for w in windowed {
            let obs = w.session.observability
            totalParallelGroups += obs.parallelToolCallCount
            if obs.maxParallelDegree > maxDegree {
                maxDegree = obs.maxParallelDegree
            }
            if obs.maxParallelDegree > 0 {
                degreeCounts[obs.maxParallelDegree, default: 0] += 1
            }
        }

        guard totalParallelGroups > 0 else { return .empty }

        // Estimate average tools per group from max degree (best available approximation)
        let avgToolsPerGroup = Double(maxDegree)

        let distribution = degreeCounts.keys.sorted().map { degree in
            ParallelToolBucket(toolCount: degree, occurrences: degreeCounts[degree, default: 0])
        }

        return ParallelToolAnalytics(
            totalParallelGroups: totalParallelGroups,
            avgToolsPerGroup: avgToolsPerGroup,
            maxParallelDegree: maxDegree,
            distribution: distribution
        )
    }

    // MARK: - Helpers

    private static func percentile(sorted values: [Double], p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let index = p * Double(values.count - 1)
        let lower = Int(index)
        let upper = min(lower + 1, values.count - 1)
        let fraction = index - Double(lower)
        return values[lower] + fraction * (values[upper] - values[lower])
    }

}

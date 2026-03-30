import Foundation

/// Pure computation from [SessionSummary] to AnalyticsData.
/// Port of server/services/analytics-engine.ts
struct AnalyticsEngine {

    static func compute(
        sessions: [(session: SessionSummary, project: Project)],
        pricingTable: [String: ModelPricing],
        from fromDate: Date? = nil,
        to toDate: Date? = nil
    ) -> AnalyticsData {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let filtered = sessions.filter { pair in
            guard let date = isoFormatter.date(from: pair.session.lastTimestamp) else { return true }
            if let fromDate, date < fromDate { return false }
            if let toDate, date > toDate { return false }
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

        for (session, project) in filtered {
            totalSessions += 1
            totalMessages += session.messageCount
            let sessionTokens = session.totalInputTokens + session.totalOutputTokens
            totalTokens += sessionTokens
            totalCacheTokens += session.totalCacheReadTokens + session.totalCacheCreationTokens

            let cost = session.estimatedCost
            totalCost += cost

            // Daily usage
            let day = dateKey(session.firstTimestamp)
            if let day {
                if var existing = dailyMap[day] {
                    existing.inputTokens += session.totalInputTokens
                    existing.outputTokens += session.totalOutputTokens
                    existing.cacheReadTokens += session.totalCacheReadTokens
                    existing.cacheCreationTokens += session.totalCacheCreationTokens
                    existing.cacheCreation5mTokens += session.totalCacheCreation5mTokens
                    existing.cacheCreation1hTokens += session.totalCacheCreation1hTokens
                    existing.sessionCount += 1
                    existing.messageCount += session.messageCount
                    existing.estimatedCost += cost
                    dailyMap[day] = existing
                } else {
                    dailyMap[day] = DailyUsage(
                        date: day,
                        inputTokens: session.totalInputTokens,
                        outputTokens: session.totalOutputTokens,
                        cacheReadTokens: session.totalCacheReadTokens,
                        cacheCreationTokens: session.totalCacheCreationTokens,
                        cacheCreation5mTokens: session.totalCacheCreation5mTokens,
                        cacheCreation1hTokens: session.totalCacheCreation1hTokens,
                        sessionCount: 1,
                        messageCount: session.messageCount,
                        estimatedCost: cost
                    )
                }
            }

            // Project costs
            if var pc = projectCostMap[project.id] {
                pc.totalCost += cost
                pc.totalTokens += sessionTokens
                pc.sessionCount += 1
                pc.messageCount += session.messageCount
                projectCostMap[project.id] = pc
            } else {
                projectCostMap[project.id] = ProjectCost(
                    projectId: project.id,
                    projectName: project.name,
                    totalCost: cost,
                    totalTokens: sessionTokens,
                    sessionCount: 1,
                    messageCount: session.messageCount
                )
            }

            // Model distribution (skip sessions with no detected model)
            let family = getModelFamily(session.primaryModel)
            guard family != "unknown" else { continue }
            if var mu = modelMap[family] {
                mu.turnCount += 1
                mu.totalInputTokens += session.totalInputTokens
                mu.totalOutputTokens += session.totalOutputTokens
                modelMap[family] = mu
            } else {
                modelMap[family] = ModelUsage(
                    model: family,
                    turnCount: 1,
                    totalInputTokens: session.totalInputTokens,
                    totalOutputTokens: session.totalOutputTokens
                )
            }
        }

        let dailyUsage = dailyMap.values.sorted { $0.date < $1.date }
        let projectCosts = projectCostMap.values.sorted { $0.totalCost > $1.totalCost }
        let modelUsage = modelMap.values.sorted {
            ($0.totalInputTokens + $0.totalOutputTokens) > ($1.totalInputTokens + $1.totalOutputTokens)
        }

        // Compute cache analytics
        let cacheAnalytics = computeCacheAnalytics(
            sessions: filtered.map(\.session),
            dailyUsage: dailyUsage,
            pricingTable: pricingTable
        )

        // Compute model efficiency and daily model cost from per-session model breakdowns
        let (modelEfficiency, dailyModelCost) = computeModelAnalytics(
            sessions: filtered,
            totalCost: totalCost
        )

        // Compute observability analytics
        let latencyAnalytics = computeLatencyAnalytics(sessions: filtered)
        let effortAnalytics = computeEffortAnalytics(sessions: filtered)
        let parallelToolAnalytics = computeParallelToolAnalytics(sessions: filtered)

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
            parallelToolAnalytics: parallelToolAnalytics
        )
    }

    // MARK: - Cache Analytics

    private static func computeCacheAnalytics(
        sessions: [SessionSummary],
        dailyUsage: [DailyUsage],
        pricingTable: [String: ModelPricing]
    ) -> CacheAnalytics {
        var totalCacheRead = 0
        var totalCacheWrite = 0
        var totalCache5m = 0
        var totalCache1h = 0
        var actualCost = 0.0
        var hypotheticalUncachedCost = 0.0

        for session in sessions {
            totalCacheRead += session.totalCacheReadTokens
            totalCacheWrite += session.totalCacheCreationTokens
            totalCache5m += session.totalCacheCreation5mTokens
            totalCache1h += session.totalCacheCreation1hTokens
            actualCost += session.estimatedCost

            // Hypothetical: if all cache reads were billed at base input price instead
            let pricing = getModelPricing(session.primaryModel, table: pricingTable)
            let cacheReadSavingsPerToken = pricing.input - pricing.cacheRead
            let savings = Double(session.totalCacheReadTokens) / 1e6 * cacheReadSavingsPerToken
            hypotheticalUncachedCost += session.estimatedCost + savings
        }

        let totalCacheTokens = totalCacheRead + totalCacheWrite
        let hitRatio = totalCacheTokens > 0 ? Double(totalCacheRead) / Double(totalCacheTokens) : 0
        let reuseRate = totalCacheWrite > 0 ? Double(totalCacheRead) / Double(totalCacheWrite) : 0
        let costSavings = hypotheticalUncachedCost - actualCost

        // Daily hit ratio
        let dailyHitRatio = dailyUsage.compactMap { day -> (date: String, ratio: Double)? in
            let total = day.cacheReadTokens + day.cacheCreationTokens
            guard total > 0 else { return nil }
            return (date: day.date, ratio: Double(day.cacheReadTokens) / Double(total))
        }

        // Tier cost breakdown: use a blended pricing (weighted by session count per model)
        let blendedPricing: ModelPricing = {
            // Use the most common model's pricing for tier cost display
            let modelCounts = sessions.reduce(into: [String: Int]()) { counts, s in
                counts[getModelFamily(s.primaryModel), default: 0] += 1
            }
            let topModel = modelCounts.max(by: { $0.value < $1.value })?.key
            return getModelPricing(topModel, table: pricingTable)
        }()
        let tierCost = CacheTierCost(
            cost5m: Double(totalCache5m) / 1e6 * blendedPricing.cacheCreation5m,
            cost1h: Double(totalCache1h) / 1e6 * blendedPricing.cacheCreation1h
        )

        // Per-session cache efficiency
        let sessionEfficiency: [SessionCacheEfficiency] = sessions.compactMap { session in
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

        // Model-aware cache savings from per-session model breakdowns
        var modelCacheReads: [String: Int] = [:]
        for session in sessions {
            for breakdown in session.modelBreakdown {
                modelCacheReads[breakdown.model, default: 0] += breakdown.cacheReadTokens
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
        sessions: [(session: SessionSummary, project: Project)],
        totalCost: Double
    ) -> ([ModelEfficiencyRow], [DailyModelCost]) {
        // Aggregate per-model metrics from session breakdowns
        var modelTurns: [String: Int] = [:]
        var modelOutput: [String: Int] = [:]
        var modelCostMap: [String: Double] = [:]

        // Daily model cost
        var dailyModelMap: [String: [String: Double]] = [:] // date -> model -> cost

        for (session, _) in sessions {
            let day = String(session.firstTimestamp.prefix(10))

            for breakdown in session.modelBreakdown {
                modelTurns[breakdown.model, default: 0] += breakdown.turnCount
                modelOutput[breakdown.model, default: 0] += breakdown.outputTokens
                modelCostMap[breakdown.model, default: 0] += breakdown.estimatedCost

                if day.count == 10 {
                    dailyModelMap[day, default: [:]][breakdown.model, default: 0] += breakdown.estimatedCost
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
        sessions: [(session: SessionSummary, project: Project)]
    ) -> LatencyAnalytics {
        let sessionsWithLatency = sessions.filter { $0.session.observability.medianTurnDurationMs != nil }
        guard !sessionsWithLatency.isEmpty else { return .empty }

        let medians = sessionsWithLatency.compactMap { $0.session.observability.medianTurnDurationMs }.sorted()
        let count = medians.count

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
        sessions: [(session: SessionSummary, project: Project)]
    ) -> EffortAnalytics {
        // Aggregate effort distribution across all sessions
        var totalLow = 0
        var totalMedium = 0
        var totalHigh = 0
        var totalUltrathink = 0

        for (session, _) in sessions {
            let dist = session.observability.effortDistribution
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
        for (session, _) in sessions {
            guard let level = session.observability.dominantEffortLevel else { continue }
            var entry = effortCostMap[level, default: (turnCount: 0, totalCost: 0)]
            entry.turnCount += session.messageCount
            entry.totalCost += session.estimatedCost
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
        for (session, _) in sessions {
            let day = String(session.firstTimestamp.prefix(10))
            guard day.count == 10 else { continue }
            let dist = session.observability.effortDistribution
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
        sessions: [(session: SessionSummary, project: Project)]
    ) -> ParallelToolAnalytics {
        var totalParallelGroups = 0
        var maxDegree = 0
        var degreeCounts: [Int: Int] = [:] // maxParallelDegree -> session count

        for (session, _) in sessions {
            let obs = session.observability
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

    private static func dateKey(_ timestamp: String) -> String? {
        guard timestamp.count >= 10 else { return nil }
        let key = String(timestamp.prefix(10))
        // Validate YYYY-MM-DD format
        guard key.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        return key
    }
}

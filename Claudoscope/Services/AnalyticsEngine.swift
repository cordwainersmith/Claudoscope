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
            dailyModelCost: dailyModelCost
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
            return pricingTable[topModel ?? "sonnet"] ?? pricingTable["sonnet"]!
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
        for i in 1..<dailyHitRatio.count {
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

    private static func dateKey(_ timestamp: String) -> String? {
        guard timestamp.count >= 10 else { return nil }
        let key = String(timestamp.prefix(10))
        // Validate YYYY-MM-DD format
        guard key.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        return key
    }
}

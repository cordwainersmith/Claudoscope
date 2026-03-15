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

            // Model distribution
            let family = getModelFamily(session.primaryModel)
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

        return AnalyticsData(
            totalSessions: totalSessions,
            totalMessages: totalMessages,
            totalTokens: totalTokens,
            totalCacheTokens: totalCacheTokens,
            totalCost: totalCost,
            dailyUsage: dailyUsage,
            projectCosts: projectCosts,
            modelUsage: modelUsage
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

import Foundation

enum AnalyticsTimeRange: String, CaseIterable, Sendable {
    case today = "today"
    case sevenDays = "7 days"
    case thirtyDays = "30 days"
    case all = "all"
    case custom = "custom"

    func dateRange(customFrom: Date, customTo: Date) -> (from: Date?, to: Date?) {
        switch self {
        case .today:
            let startOfToday = Calendar.current.startOfDay(for: Date())
            return (startOfToday, nil)
        case .sevenDays:
            return (Calendar.current.date(byAdding: .day, value: -7, to: Date()), nil)
        case .thirtyDays:
            return (Calendar.current.date(byAdding: .day, value: -30, to: Date()), nil)
        case .all:
            return (nil, nil)
        case .custom:
            // End of customTo day
            let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: customTo))
            return (Calendar.current.startOfDay(for: customFrom), endOfDay)
        }
    }
}

struct AnalyticsData: Sendable {
    let totalSessions: Int
    let totalMessages: Int
    let totalTokens: Int
    let totalCacheTokens: Int
    let totalCost: Double
    let dailyUsage: [DailyUsage]
    let projectCosts: [ProjectCost]
    let modelUsage: [ModelUsage]
    let cacheAnalytics: CacheAnalytics
    let modelEfficiency: [ModelEfficiencyRow]
    let dailyModelCost: [DailyModelCost]

    static let empty = AnalyticsData(
        totalSessions: 0, totalMessages: 0, totalTokens: 0, totalCacheTokens: 0, totalCost: 0,
        dailyUsage: [], projectCosts: [], modelUsage: [],
        cacheAnalytics: .empty, modelEfficiency: [], dailyModelCost: []
    )
}

// MARK: - Cache Analytics

struct CacheAnalytics: Sendable {
    let hitRatio: Double
    let totalCacheReadTokens: Int
    let totalCacheWriteTokens: Int
    let costSavings: Double
    let hypotheticalUncachedCost: Double
    let actualCost: Double
    let averageReuseRate: Double
    let dailyHitRatio: [(date: String, ratio: Double)]
    let totalCache5mTokens: Int
    let totalCache1hTokens: Int
    let tierCostBreakdown: CacheTierCost
    let sessionEfficiency: [SessionCacheEfficiency]
    let modelSavings: [ModelCacheSavings]
    let cacheBustingDays: [String]

    static let empty = CacheAnalytics(
        hitRatio: 0, totalCacheReadTokens: 0, totalCacheWriteTokens: 0,
        costSavings: 0, hypotheticalUncachedCost: 0, actualCost: 0,
        averageReuseRate: 0, dailyHitRatio: [],
        totalCache5mTokens: 0, totalCache1hTokens: 0,
        tierCostBreakdown: CacheTierCost(cost5m: 0, cost1h: 0),
        sessionEfficiency: [], modelSavings: [], cacheBustingDays: []
    )
}

struct CacheTierCost: Sendable {
    let cost5m: Double
    let cost1h: Double
}

struct SessionCacheEfficiency: Identifiable, Sendable {
    var id: String { sessionId }
    let sessionId: String
    let sessionTitle: String
    let hitRatio: Double
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let savingsAmount: Double
    let primaryModel: String?
}

struct ModelCacheSavings: Identifiable, Sendable {
    var id: String { model }
    let model: String
    let cacheReadTokens: Int
    let savingsPerMTok: Double
    let totalSavings: Double
}

// MARK: - Model Efficiency

struct ModelEfficiencyRow: Identifiable, Sendable {
    var id: String { model }
    let model: String
    let turnCount: Int
    let totalOutputTokens: Int
    let avgOutputPerTurn: Int
    let totalCost: Double
    let costPerTurn: Double
    let percentOfTotalCost: Double
}

struct DailyModelCost: Identifiable, Sendable {
    var id: String { "\(date)-\(model)" }
    let date: String
    let model: String
    let cost: Double
}

struct WhatIfSavings: Sendable {
    let currentCost: Double
    let hypotheticalCost: Double
    let savings: Double
    let savingsPercent: Double
    let turnsAffected: Int
}

struct DailyUsage: Identifiable, Sendable {
    var id: String { date }
    let date: String
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheCreationTokens: Int
    var cacheCreation5mTokens: Int
    var cacheCreation1hTokens: Int
    var sessionCount: Int
    var messageCount: Int
    var estimatedCost: Double
}

struct ProjectCost: Identifiable, Sendable {
    var id: String { projectId }
    let projectId: String
    let projectName: String
    var totalCost: Double
    var totalTokens: Int
    var sessionCount: Int
    var messageCount: Int
}

struct ModelUsage: Identifiable, Sendable {
    var id: String { model }
    let model: String
    var turnCount: Int
    var totalInputTokens: Int
    var totalOutputTokens: Int
}

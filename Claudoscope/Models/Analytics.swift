import Foundation

enum AnalyticsTimeRange: String, CaseIterable, Sendable {
    case sevenDays = "7 days"
    case thirtyDays = "30 days"
    case all = "all"
    case custom = "custom"

    func dateRange(customFrom: Date, customTo: Date) -> (from: Date?, to: Date?) {
        switch self {
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

    static let empty = AnalyticsData(
        totalSessions: 0, totalMessages: 0, totalTokens: 0, totalCacheTokens: 0, totalCost: 0,
        dailyUsage: [], projectCosts: [], modelUsage: []
    )
}

struct DailyUsage: Identifiable, Sendable {
    var id: String { date }
    let date: String
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheCreationTokens: Int
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

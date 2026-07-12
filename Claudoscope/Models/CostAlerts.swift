import Foundation

// MARK: - Configuration

enum CostAlertUnit: String, Codable, Sendable, CaseIterable {
    case dollars
    case tokens
}

struct CostAlertRule: Codable, Sendable, Equatable {
    var enabled: Bool
    var threshold: Double
    var unit: CostAlertUnit
}

struct CostAlertConfig: Codable, Sendable, Equatable {
    var masterEnabled: Bool
    var session: CostAlertRule
    var rolling: CostAlertRule
    var rollingWindowMinutes: Int
    var daily: CostAlertRule
    var monthly: CostAlertRule

    static let `default` = CostAlertConfig(
        masterEnabled: false,
        session: CostAlertRule(enabled: true, threshold: 5, unit: .dollars),
        rolling: CostAlertRule(enabled: true, threshold: 10, unit: .dollars),
        rollingWindowMinutes: 60,
        daily: CostAlertRule(enabled: true, threshold: 25, unit: .dollars),
        monthly: CostAlertRule(enabled: true, threshold: 200, unit: .dollars)
    )

    static let rollingWindowOptions: [(minutes: Int, label: String)] = [
        (5, "5 min"),
        (15, "15 min"),
        (60, "1 hour"),
        (240, "4 hours"),
    ]

    static func windowLabel(minutes: Int) -> String {
        rollingWindowOptions.first(where: { $0.minutes == minutes })?.label ?? "\(minutes) min"
    }

    static func windowPhrase(minutes: Int) -> String {
        switch minutes {
        case 5: return "Last 5 minutes"
        case 15: return "Last 15 minutes"
        case 60: return "Last hour"
        case 240: return "Last 4 hours"
        default: return "Last \(minutes) minutes"
        }
    }
}

// MARK: - Snapshot (built by SessionStore, consumed by the engine)

struct CostSessionFigure: Sendable {
    let id: String
    let title: String
    let cost: Double
    let tokens: Int
}

struct CostSnapshot: Sendable {
    /// Lifetime totals across all CLI sessions (incl. subagents) + Cowork.
    let cumulativeCost: Double
    let cumulativeTokens: Int
    /// Sessions with activity in the last 30 minutes, subagents excluded.
    let recentSessions: [CostSessionFigure]
    let todayCost: Double
    let todayTokens: Int
    let monthCost: Double
    let monthTokens: Int
    let dayKey: String
    let monthKey: String
}

// MARK: - Events

enum CostAlertKind: String, Codable, Sendable {
    case session
    case rolling
    case daily
    case monthly
}

struct CostAlertEvent: Identifiable, Sendable {
    let id = UUID()
    let kind: CostAlertKind
    /// Session id, day key, month key, or "rolling".
    let scopeId: String
    /// Session title, or a window label for the other kinds.
    let scopeTitle: String
    let unit: CostAlertUnit
    let measured: Double
    /// The doubled threshold actually crossed (base * 2^level).
    let effectiveThreshold: Double
    /// 0 = base threshold, 1 = 2x, 2 = 4x, ...
    let level: Int

    var headline: String {
        let limit = Self.amount(effectiveThreshold, unit: unit)
        switch kind {
        case .session: return "Session over \(limit)"
        case .rolling: return "Spend over \(limit) in the \(scopeTitle.lowercased())"
        case .daily: return "Today over \(limit)"
        case .monthly: return "This month over \(limit)"
        }
    }

    var detail: String {
        let now = Self.amount(measured, unit: unit)
        switch kind {
        case .session: return "\"\(scopeTitle)\" is at \(now)."
        case .rolling: return "\(now) across all sessions in the \(scopeTitle.lowercased())."
        case .daily: return "Today's total is \(now)."
        case .monthly: return "This month's total is \(now)."
        }
    }

    static func amount(_ value: Double, unit: CostAlertUnit) -> String {
        switch unit {
        case .dollars: return "est. \(formatCost(value))"
        case .tokens: return "\(formatTokens(Int(value))) tokens"
        }
    }
}

// MARK: - Fired state (persisted so relaunch does not re-fire)

struct CostAlertFiredState: Codable, Sendable, Equatable {
    struct SessionLevel: Codable, Sendable, Equatable {
        let id: String
        var level: Int
    }

    /// Insertion-ordered, capped at `sessionLevelCap` (oldest dropped).
    var sessionLevels: [SessionLevel] = []
    var dailyKey: String = ""
    var dailyLevel: Int = 0
    var monthlyKey: String = ""
    var monthlyLevel: Int = 0
    /// In-memory episode only; the service zeroes it after loading from disk.
    var rollingLevel: Int = 0

    static let sessionLevelCap = 200

    func sessionLevel(for id: String) -> Int {
        sessionLevels.first(where: { $0.id == id })?.level ?? 0
    }

    mutating func setSessionLevel(_ level: Int, for id: String) {
        if let idx = sessionLevels.firstIndex(where: { $0.id == id }) {
            sessionLevels[idx].level = level
        } else {
            sessionLevels.append(SessionLevel(id: id, level: level))
            if sessionLevels.count > Self.sessionLevelCap {
                sessionLevels.removeFirst(sessionLevels.count - Self.sessionLevelCap)
            }
        }
    }
}

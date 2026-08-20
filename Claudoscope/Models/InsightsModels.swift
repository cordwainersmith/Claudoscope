import Foundation

// MARK: - Session Facets (~/.claude/usage-data/facets/<sessionId>.json)

/// One session's LLM-classified facets, written by Claude Code's /insights.
/// Read-only consumer: Claudoscope never generates these.
struct SessionFacet: Identifiable, Sendable, Decodable {
    var id: String { sessionId }
    let sessionId: String
    let underlyingGoal: String?
    let goalCategories: [String: Int]?
    let outcomeRaw: String?
    let userSatisfactionCounts: [String: Int]?
    let claudeHelpfulness: String?
    let sessionType: String?
    let frictionCounts: [String: Int]?
    let frictionDetail: String?
    let primarySuccess: String?
    let briefSummary: String?

    var outcome: FacetOutcome { FacetOutcome(raw: outcomeRaw) }
    var frictionTotal: Int { frictionCounts?.values.reduce(0, +) ?? 0 }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case underlyingGoal = "underlying_goal"
        case goalCategories = "goal_categories"
        case outcomeRaw = "outcome"
        case userSatisfactionCounts = "user_satisfaction_counts"
        case claudeHelpfulness = "claude_helpfulness"
        case sessionType = "session_type"
        case frictionCounts = "friction_counts"
        case frictionDetail = "friction_detail"
        case primarySuccess = "primary_success"
        case briefSummary = "brief_summary"
    }
}

/// Lenient outcome mapping so an unrecognized future value never breaks decode;
/// it lands in .unclear and stays visible.
enum FacetOutcome: String, CaseIterable, Sendable {
    case fullyAchieved
    case mostlyAchieved
    case partiallyAchieved
    case notAchieved
    case unclear

    init(raw: String?) {
        switch raw {
        case "fully_achieved": self = .fullyAchieved
        case "mostly_achieved": self = .mostlyAchieved
        case "partially_achieved": self = .partiallyAchieved
        case "not_achieved": self = .notAchieved
        default: self = .unclear
        }
    }

    var label: String {
        switch self {
        case .fullyAchieved: return "Fully achieved"
        case .mostlyAchieved: return "Mostly achieved"
        case .partiallyAchieved: return "Partially achieved"
        case .notAchieved: return "Not achieved"
        case .unclear: return "Unclear"
        }
    }

    /// Ordering for the scaleLow..scaleMax color ramp (best first).
    var rank: Int {
        switch self {
        case .fullyAchieved: return 0
        case .mostlyAchieved: return 1
        case .partiallyAchieved: return 2
        case .notAchieved: return 3
        case .unclear: return 4
        }
    }
}

// MARK: - Session Meta (~/.claude/usage-data/session-meta/<sessionId>.json)

/// Companion stats file; only the fields the detail panel shows are decoded.
struct SessionMetaFacet: Sendable, Decodable {
    let projectPath: String?
    let startTime: String?
    let durationMinutes: Double?
    let firstPrompt: String?
    let userInterruptions: Int?
    let toolErrors: Int?
    let linesAdded: Int?
    let linesRemoved: Int?
    let filesModified: Int?

    enum CodingKeys: String, CodingKey {
        case projectPath = "project_path"
        case startTime = "start_time"
        case durationMinutes = "duration_minutes"
        case firstPrompt = "first_prompt"
        case userInterruptions = "user_interruptions"
        case toolErrors = "tool_errors"
        case linesAdded = "lines_added"
        case linesRemoved = "lines_removed"
        case filesModified = "files_modified"
    }
}

// MARK: - Joined Insight

/// A facet joined against the store's parsed sessions. summary is nil when the
/// transcript is gone (cleanup) or was never in the local corpus.
struct SessionInsight: Identifiable, Sendable {
    var id: String { facet.sessionId }
    let facet: SessionFacet
    let meta: SessionMetaFacet?
    let summary: SessionSummary?
}

struct InsightsCoverage: Sendable {
    let facetCount: Int
    let storeSessionCount: Int
    let latestFacetDate: Date?
}

struct InsightsData: Sendable {
    let insights: [SessionInsight]
    let outcomeDistribution: [(outcome: FacetOutcome, count: Int)]
    let frictionTotals: [(kind: String, count: Int)]
    let coverage: InsightsCoverage

    static let empty = InsightsData(
        insights: [],
        outcomeDistribution: [],
        frictionTotals: [],
        coverage: InsightsCoverage(facetCount: 0, storeSessionCount: 0, latestFacetDate: nil)
    )
}

// MARK: - Insights Engine

/// Pure join + aggregate; no store access.
enum InsightsEngine {
    static func build(
        facets: [(facet: SessionFacet, fileDate: Date?)],
        meta: [String: SessionMetaFacet],
        summariesById: [String: SessionSummary],
        storeSessionCount: Int
    ) -> InsightsData {
        let insights = facets
            .map { entry in
                SessionInsight(
                    facet: entry.facet,
                    meta: meta[entry.facet.sessionId],
                    summary: summariesById[entry.facet.sessionId]
                )
            }
            .sorted { a, b in
                let dateA = a.meta?.startTime ?? ""
                let dateB = b.meta?.startTime ?? ""
                if dateA != dateB { return dateA > dateB }
                return a.id < b.id
            }

        var outcomeCounts: [FacetOutcome: Int] = [:]
        var frictionCounts: [String: Int] = [:]
        for insight in insights {
            outcomeCounts[insight.facet.outcome, default: 0] += 1
            for (kind, count) in insight.facet.frictionCounts ?? [:] {
                frictionCounts[kind, default: 0] += count
            }
        }

        let outcomeDistribution = FacetOutcome.allCases
            .sorted { $0.rank < $1.rank }
            .compactMap { outcome -> (outcome: FacetOutcome, count: Int)? in
                guard let count = outcomeCounts[outcome], count > 0 else { return nil }
                return (outcome, count)
            }

        let frictionTotals = frictionCounts
            .map { (kind: $0.key, count: $0.value) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.kind < $1.kind
            }

        return InsightsData(
            insights: insights,
            outcomeDistribution: outcomeDistribution,
            frictionTotals: frictionTotals,
            coverage: InsightsCoverage(
                facetCount: insights.count,
                storeSessionCount: storeSessionCount,
                latestFacetDate: facets.compactMap(\.fileDate).max()
            )
        )
    }
}

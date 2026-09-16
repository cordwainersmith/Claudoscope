import Foundation

// MARK: - Aggregates

/// Cross-session spend for one skill, joined against the installed skills.
struct SkillCostAggregate: Sendable, Identifiable, Equatable {
    var id: String { skill }
    /// Canonical (bare) skill name. Claude Code tags the same skill both bare
    /// and plugin-qualified, so the raw tags are folded onto one key here.
    let skill: String
    let sessionCount: Int
    let turnCount: Int
    let estimatedCost: Double
    let inputTokens: Int
    let outputTokens: Int
    /// False when the tag matches no currently installed skill: it ran in an
    /// older session and has since been removed or renamed.
    let isInstalled: Bool
}

/// Cross-session spend for one MCP tool. Server and tool stay separate so the
/// MCPs rail can roll up by server without re-splitting a composite key.
struct McpCostAggregate: Sendable, Identifiable, Equatable {
    var id: String { server + "/" + tool }
    let server: String
    let tool: String
    let sessionCount: Int
    let turnCount: Int
    let estimatedCost: Double
}

/// Cross-session spend for one subagent type. Folded from whole subagent
/// sessions rather than per-record, because `attributionAgent` is a scalar.
struct AgentCostAggregate: Sendable, Identifiable, Equatable {
    var id: String { agent }
    let agent: String
    let sessionCount: Int
    let estimatedCost: Double
    let inputTokens: Int
    let outputTokens: Int
    /// Model families actually observed running as this agent, most frequent
    /// first. The Agents rail compares this against the agent definition's
    /// declared `model`, which is where a stale or overridden definition shows.
    let observedModels: [String]
}

/// One fold's worth of attribution.
///
/// `skills` and `mcps` are INDEPENDENT partial partitions of `totalCost`, not
/// two slices of one pie: a single billed record can carry both a skill tag and
/// an MCP tag, so their sums can together exceed the total. Each therefore gets
/// its own remainder, and neither may be normalized to 100%.
struct AttributionRollup: Sendable, Equatable {
    let skills: [SkillCostAggregate]
    let mcps: [McpCostAggregate]
    let agents: [AgentCostAggregate]
    /// Total billed cost of the windowed sessions, the denominator both
    /// remainders are measured against.
    let totalCost: Double

    var skillAttributedCost: Double { skills.reduce(0) { $0 + $1.estimatedCost } }
    var mcpAttributedCost: Double { mcps.reduce(0) { $0 + $1.estimatedCost } }

    /// Clamped at zero to absorb floating-point drift. Never render attributed
    /// rows without showing these.
    var skillUnattributedCost: Double { max(0, totalCost - skillAttributedCost) }
    var mcpUnattributedCost: Double { max(0, totalCost - mcpAttributedCost) }

    var skillCoverage: Double { totalCost > 0 ? skillAttributedCost / totalCost : 0 }
    var mcpCoverage: Double { totalCost > 0 ? mcpAttributedCost / totalCost : 0 }

    /// True when no session in the window carries any attribution at all, which
    /// means the transcripts predate Claude Code 2.1.24x rather than that
    /// nothing was spent. The UI must say so instead of showing empty tables.
    var isEmpty: Bool { skills.isEmpty && mcps.isEmpty && agents.isEmpty }

    static let empty = AttributionRollup(skills: [], mcps: [], agents: [], totalCost: 0)
}

// MARK: - Engine

/// Pure fold over SessionSummary attribution, in the HookRuntimeEngine style:
/// no store access, recomputed by SessionStore after session reloads.
///
/// Taking day bounds lets one engine serve both the un-windowed config rails
/// and the date-correct Analytics tab, without adding a field to AnalyticsData.
enum AttributionEngine {

    /// - Parameters:
    ///   - sessions: every session, subagents included. Skill and MCP spend is
    ///     folded from `dailyContributions` so the window is exact; agent spend
    ///     is folded from whole subagent sessions.
    ///   - skills: installed skills, used only to mark `isInstalled`.
    ///   - fromDay/toDay: half-open LOCAL day-string bounds `[from, to)`,
    ///     matching AnalyticsEngine. Nil for all time.
    static func aggregate(
        sessions: [SessionSummary],
        skills: [SkillEntry] = [],
        fromDay: String? = nil,
        toDay: String? = nil
    ) -> AttributionRollup {
        func inRange(_ date: String) -> Bool {
            if let fromDay, date < fromDay { return false }
            if let toDay, date >= toDay { return false }
            return true
        }

        struct Acc {
            var sessions = Set<String>()
            var turns = 0
            var cost = 0.0
            var input = 0
            var output = 0
            var models: [String: Int] = [:]
        }
        var skillAcc: [String: Acc] = [:]
        var mcpAcc: [String: (server: String, tool: String, acc: Acc)] = [:]
        var agentAcc: [String: Acc] = [:]
        var totalCost = 0.0

        for session in sessions {
            let days = session.dailyContributions.filter { inRange($0.date) }
            guard !days.isEmpty else { continue }

            let windowCost = days.reduce(0.0) { $0 + $1.estimatedCost }
            totalCost += windowCost

            for day in days {
                for row in day.skillBreakdown ?? [] {
                    let key = canonicalSkillKey(row.skill)
                    var a = skillAcc[key] ?? Acc()
                    a.sessions.insert(session.id)
                    a.turns += row.turnCount
                    a.cost += row.estimatedCost
                    a.input += row.inputTokens
                    a.output += row.outputTokens
                    skillAcc[key] = a
                }
                for row in day.mcpBreakdown ?? [] {
                    var entry = mcpAcc[row.id] ?? (row.server, row.tool, Acc())
                    entry.acc.sessions.insert(session.id)
                    entry.acc.turns += row.turnCount
                    entry.acc.cost += row.estimatedCost
                    entry.acc.input += row.inputTokens
                    entry.acc.output += row.outputTokens
                    mcpAcc[row.id] = entry
                }
            }

            // Agent spend is whole-session: the tag applies to the entire
            // subagent file, so the windowed day cost is what it contributed.
            if let agent = session.attributionAgent, !agent.isEmpty {
                var a = agentAcc[agent] ?? Acc()
                a.sessions.insert(session.id)
                a.cost += windowCost
                a.input += days.reduce(0) { $0 + $1.inputTokens }
                a.output += days.reduce(0) { $0 + $1.outputTokens }
                if let model = session.primaryModel {
                    a.models[getModelFamily(model), default: 0] += 1
                }
                agentAcc[agent] = a
            }
        }

        let installed = Set(skills.map { canonicalSkillKey($0.name) })

        let skillRows = skillAcc.map { key, a in
            SkillCostAggregate(
                skill: key,
                sessionCount: a.sessions.count,
                turnCount: a.turns,
                estimatedCost: a.cost,
                inputTokens: a.input,
                outputTokens: a.output,
                isInstalled: installed.contains(key)
            )
        }.sorted { costDescending($0.estimatedCost, $1.estimatedCost, $0.id, $1.id) }

        let mcpRows = mcpAcc.values.map { entry in
            McpCostAggregate(
                server: entry.server,
                tool: entry.tool,
                sessionCount: entry.acc.sessions.count,
                turnCount: entry.acc.turns,
                estimatedCost: entry.acc.cost
            )
        }.sorted { costDescending($0.estimatedCost, $1.estimatedCost, $0.id, $1.id) }

        let agentRows = agentAcc.map { key, a in
            AgentCostAggregate(
                agent: key,
                sessionCount: a.sessions.count,
                estimatedCost: a.cost,
                inputTokens: a.input,
                outputTokens: a.output,
                observedModels: a.models
                    .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                    .map(\.key)
            )
        }.sorted { costDescending($0.estimatedCost, $1.estimatedCost, $0.id, $1.id) }

        return AttributionRollup(
            skills: skillRows, mcps: mcpRows, agents: agentRows, totalCost: totalCost
        )
    }

    /// Date-bound convenience matching `AnalyticsEngine.compute`, so a caller
    /// that already has the analytics window can pass it straight through.
    static func aggregate(
        sessions: [SessionSummary],
        skills: [SkillEntry] = [],
        from: Date?,
        to: Date?
    ) -> AttributionRollup {
        aggregate(
            sessions: sessions,
            skills: skills,
            fromDay: from.map { AnalyticsEngine.dayKey($0) },
            toDay: to.map { AnalyticsEngine.dayKey($0) }
        )
    }

    /// Stable ordering: cost descending, id ascending as the tiebreak so the
    /// tables do not reshuffle between recomputes.
    private static func costDescending(_ a: Double, _ b: Double, _ ida: String, _ idb: String) -> Bool {
        if a != b { return a > b }
        return ida < idb
    }

    /// Claude Code writes the same skill both bare ("frontend-design") and
    /// plugin-qualified ("frontend-design:frontend-design"), and at least one
    /// skill appears in both forms in a single corpus. Folding onto the bare
    /// name keeps it one row and lets it join `SkillEntry.name`.
    ///
    /// The tradeoff is that two same-named skills in different plugins collapse
    /// together. That is the condition SKL015 flags as a config problem in its
    /// own right, so merging here does not hide anything that is not already
    /// reported.
    static func canonicalSkillKey(_ tag: String) -> String {
        guard let idx = tag.lastIndex(of: ":") else { return tag }
        let bare = tag[tag.index(after: idx)...]
        return bare.isEmpty ? tag : String(bare)
    }

    /// True when an attribution tag refers to this installed skill.
    static func matchSkill(_ tag: String, to entry: SkillEntry) -> Bool {
        canonicalSkillKey(tag) == canonicalSkillKey(entry.name)
    }

    /// Claude Code writes the agent type as invoked ("Explore"), while an agent
    /// definition's `name` is whatever its frontmatter says ("explore"), so the
    /// join is case-insensitive.
    static func matchAgent(_ tag: String, to entry: AgentEntry) -> Bool {
        tag.compare(entry.name, options: .caseInsensitive) == .orderedSame
    }
}

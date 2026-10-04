import Foundation

/// Pure derivation of Fleet board state. No IO, no main-actor state, so the
/// precedence rules are unit-testable in isolation.
///
/// Precedence per session:
///  1. A hook event that is newer than the transcript's last activity (and
///     newer than a registry "busy" transition) wins: it is the only source
///     that knows *why* the agent stopped.
///  2. Otherwise the live registry status (Claude Code's own view of itself).
///  3. Otherwise a registry entry that vanished mid-turn (a crash or kill).
///  4. Otherwise transcript recency.
enum FleetStateEngine {

    /// A wait that has gone on for this long escalates (tint only, no
    /// notification).
    static let longWait: TimeInterval = 600
    /// A waiting agent escalates when its prompt cache expires within this.
    static let cacheExpiryWarning: TimeInterval = 60

    static func state(
        summary: SessionSummary,
        registry: RegistryEntry?,
        hookEvent: FleetHookEvent?,
        exit: RegistryExit? = nil,
        now: Date,
        activeThreshold: TimeInterval
    ) -> (state: FleetState, since: Date, failureReason: String?) {
        let lastActivity = ISO8601.parse(summary.lastTimestamp) ?? .distantPast

        if let event = hookEvent,
           !hookEventIsStale(event, lastTimestamp: summary.lastTimestamp, registry: registry) {
            switch event.kind {
            case .permissionPrompt:
                return (.blockedOnPermission, event.receivedAt, nil)
            case .elicitation, .genericBlock:
                return (.waitingOnUser(reason: event.message.flatMap(nonEmpty) ?? "Input needed"), event.receivedAt, nil)
            case .yourTurn:
                return (.waitingOnUser(reason: "Finished, ready for review"), event.receivedAt, nil)
            }
        }

        if let registry {
            let since = registry.statusDate ?? registry.startedDate ?? lastActivity
            switch registry.status {
            case "waiting", "blocked", "needs_input":
                return (.waitingOnUser(reason: registry.waitingFor.flatMap(nonEmpty) ?? "Input needed"), since, nil)
            case "busy", "shell":
                return (.working, since, nil)
            case "idle":
                return (.idle, since, nil)
            case "done":
                return (.done, since, nil)
            default:
                // Unknown status: fall through to transcript rules, but a live
                // process is never "done".
                if now.timeIntervalSince(lastActivity) < activeThreshold {
                    return (.working, lastActivity, nil)
                }
                return (.idle, lastActivity, nil)
            }
        }

        if registry == nil, let exit, exitedMidTurn(exit, hookEvent: hookEvent, lastTimestamp: summary.lastTimestamp) {
            return (.failed, exit.at, "Process exited mid-turn")
        }

        if now.timeIntervalSince(lastActivity) < activeThreshold {
            return (.working, lastActivity, nil)
        }
        if summary.hasError {
            return (.failed, lastActivity, nil)
        }
        return (.done, lastActivity, nil)
    }

    /// A vanished registry entry counts as a crash only if Claude Code last
    /// reported it busy, no Stop hook arrived after that report, and the
    /// transcript has not moved since the exit (a resume clears it).
    static func exitedMidTurn(_ exit: RegistryExit, hookEvent: FleetHookEvent?, lastTimestamp: String) -> Bool {
        guard exit.entry.status == "busy" || exit.entry.status == "shell" else { return false }
        if let hookEvent, hookEvent.kind == .yourTurn,
           hookEvent.receivedAt >= (exit.entry.statusDate ?? .distantPast) {
            return false
        }
        let last = ISO8601.parse(lastTimestamp) ?? .distantPast
        return last <= exit.at
    }

    /// A hook event is stale once the transcript moved past it (the user
    /// answered) or the registry reports the process busy again after it.
    static func hookEventIsStale(_ event: FleetHookEvent, lastTimestamp: String, registry: RegistryEntry?) -> Bool {
        if let last = ISO8601.parse(lastTimestamp), last > event.receivedAt {
            return true
        }
        if let registry, let statusDate = registry.statusDate, statusDate > event.receivedAt,
           registry.status == "busy" || registry.status == "shell" {
            return true
        }
        return false
    }

    static func buildAgents(
        sessions: [SessionSummary],
        registry: [RegistryEntry],
        hookEvents: [String: FleetHookEvent],
        exits: [String: RegistryExit] = [:],
        now: Date,
        activeThreshold: TimeInterval,
        recentWindow: TimeInterval
    ) -> [FleetAgent] {
        let registryBySession = registryBySession(registry)
        var subagentsById: [String: SessionSummary] = [:]
        for s in sessions where s.isSubagent {
            if let aid = s.agentId { subagentsById[aid] = s }
        }

        var agents: [FleetAgent] = []
        for summary in sessions where !summary.isSubagent {
            let entry = registryBySession[summary.id]
            let isLive = entry != nil
            if !isLive {
                guard let last = ISO8601.parse(summary.lastTimestamp),
                      now.timeIntervalSince(last) <= recentWindow else { continue }
            }
            let derived = state(
                summary: summary, registry: entry, hookEvent: hookEvents[summary.id],
                exit: exits[summary.id], now: now, activeThreshold: activeThreshold
            )
            agents.append(FleetAgent(
                summary: summary,
                registry: entry,
                state: derived.state,
                since: derived.since,
                isLive: isLive,
                isBackgroundJob: (entry?.isBackground ?? false) || summary.sessionKind == "bg",
                isBypass: summary.everBypassedPermissions == true,
                failureReason: derived.failureReason,
                subagents: descendants(of: summary, in: subagentsById)
            ))
        }
        return agents.sorted {
            if $0.state.sortRank != $1.state.sortRank { return $0.state.sortRank < $1.state.sortRank }
            if $0.since != $1.since { return $0.since < $1.since }
            return $0.id < $1.id
        }
    }

    /// One entry per session. Two processes on one session id (resume after a
    /// crash): keep the most recently updated one.
    static func registryBySession(_ registry: [RegistryEntry]) -> [String: RegistryEntry] {
        var bySession: [String: RegistryEntry] = [:]
        for entry in registry {
            if let existing = bySession[entry.sessionId],
               (existing.updatedAt ?? 0) > (entry.updatedAt ?? 0) {
                continue
            }
            bySession[entry.sessionId] = entry
        }
        return bySession
    }

    /// True when some agent's derived state can change with no file, hook or
    /// registry event: a non-live agent still inside the active threshold, or
    /// an agent waiting on the user (its escalation flags move with the clock).
    static func needsPeriodicRefresh(_ agents: [FleetAgent]) -> Bool {
        agents.contains { (!$0.isLive && $0.state == .working) || $0.state.needsAttention }
    }

    /// Agents bucketed by project name, groups sorted case-insensitively, each
    /// group keeping the input order.
    static func groupedByProject(_ agents: [FleetAgent]) -> [(project: String, agents: [FleetAgent])] {
        var order: [String] = []
        var groups: [String: [FleetAgent]] = [:]
        for agent in agents {
            let name = agent.projectName
            if groups[name] == nil { order.append(name) }
            groups[name, default: []].append(agent)
        }
        return order
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { ($0, groups[$0] ?? []) }
    }

    /// Agents that need the user, oldest wait first.
    static func attentionQueue(_ agents: [FleetAgent]) -> [FleetAgent] {
        agents.filter { $0.state.needsAttention }.sorted {
            if $0.since != $1.since { return $0.since < $1.since }
            return $0.id < $1.id
        }
    }

    /// Maps a hook spool payload to a fleet event kind. Nil means "not a state
    /// change" (idle reminders, auth success).
    static func classifyHookEvent(notificationType: String?, hookEventName: String?, message: String?) -> FleetHookEvent.Kind? {
        if hookEventName == "Stop" { return .yourTurn }
        let type = (notificationType ?? "").lowercased()
        if type.contains("idle") { return nil }
        if type.contains("auth") { return nil }
        if type.contains("permission") { return .permissionPrompt }
        if type.contains("elicitation") { return .elicitation }
        if type.isEmpty, let message, message.localizedCaseInsensitiveContains("permission") {
            return .permissionPrompt
        }
        return .genericBlock
    }

    /// Agents active in each of the last `hours` hourly buckets, oldest first.
    /// A session counts for every bucket its first..last activity overlaps
    /// (live sessions run to `now`), so a long idle gap reads as active.
    static func hourlyConcurrency(_ agents: [FleetAgent], now: Date, hours: Int = 24) -> [Int] {
        let spans: [(Date, Date)] = agents.map { agent in
            let end = agent.isLive ? now : (ISO8601.parse(agent.summary.lastTimestamp) ?? agent.since)
            return (agent.startedAt, end)
        }
        return (0..<hours).map { i in
            let bucketStart = now.addingTimeInterval(-Double(hours - i) * 3600)
            let bucketEnd = bucketStart.addingTimeInterval(3600)
            return spans.filter { $0.0 < bucketEnd && $0.1 >= bucketStart }.count
        }
    }

    /// Cost the board's sessions incurred on the local calendar day of `now`.
    static func spendOnDay(_ agents: [FleetAgent], now: Date) -> Double {
        let key = ISO8601.localDayKey(for: now)
        return agents.reduce(0) { $0 + $1.cost(onDay: key) }
    }

    /// Subagents reachable from a session through spawnedAgentIds, the same
    /// edges the subagent tree uses. Visited-set guarded against cycles.
    static func descendants(of session: SessionSummary, in subagentsById: [String: SessionSummary]) -> [SessionSummary] {
        var found: [SessionSummary] = []
        var visited = Set<String>()
        var queue = session.spawnedAgentIds
        while let id = queue.popLast() {
            guard visited.insert(id).inserted, let sub = subagentsById[id] else { continue }
            found.append(sub)
            queue.append(contentsOf: sub.spawnedAgentIds)
        }
        return found
    }

    private static func nonEmpty(_ s: String) -> String? {
        s.isEmpty ? nil : s
    }
}

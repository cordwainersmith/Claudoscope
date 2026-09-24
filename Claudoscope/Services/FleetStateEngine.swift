import Foundation

/// Pure derivation of Fleet board state. No IO, no main-actor state, so the
/// precedence rules are unit-testable in isolation.
///
/// Precedence per session:
///  1. A hook event that is newer than the transcript's last activity (and
///     newer than a registry "busy" transition) wins: it is the only source
///     that knows *why* the agent stopped.
///  2. Otherwise the live registry status (Claude Code's own view of itself).
///  3. Otherwise transcript recency.
enum FleetStateEngine {

    static func state(
        summary: SessionSummary,
        registry: RegistryEntry?,
        hookEvent: FleetHookEvent?,
        now: Date,
        activeThreshold: TimeInterval
    ) -> (state: FleetState, since: Date) {
        let lastActivity = ISO8601.parse(summary.lastTimestamp) ?? .distantPast

        if let event = hookEvent,
           !hookEventIsStale(event, lastTimestamp: summary.lastTimestamp, registry: registry) {
            switch event.kind {
            case .permissionPrompt:
                return (.blockedOnPermission, event.receivedAt)
            case .elicitation, .genericBlock:
                return (.waitingOnUser(reason: event.message.flatMap(nonEmpty) ?? "Input needed"), event.receivedAt)
            case .yourTurn:
                return (.waitingOnUser(reason: "Finished, ready for review"), event.receivedAt)
            }
        }

        if let registry {
            let since = registry.statusDate ?? registry.startedDate ?? lastActivity
            switch registry.status {
            case "waiting", "blocked", "needs_input":
                return (.waitingOnUser(reason: registry.waitingFor.flatMap(nonEmpty) ?? "Input needed"), since)
            case "busy", "shell":
                return (.working, since)
            case "idle":
                return (.idle, since)
            case "done":
                return (.done, since)
            default:
                // Unknown status: fall through to transcript rules, but a live
                // process is never "done".
                if now.timeIntervalSince(lastActivity) < activeThreshold {
                    return (.working, lastActivity)
                }
                return (.idle, lastActivity)
            }
        }

        if now.timeIntervalSince(lastActivity) < activeThreshold {
            return (.working, lastActivity)
        }
        if summary.hasError {
            return (.failed, lastActivity)
        }
        return (.done, lastActivity)
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
        now: Date,
        activeThreshold: TimeInterval,
        recentWindow: TimeInterval
    ) -> [FleetAgent] {
        var registryBySession: [String: RegistryEntry] = [:]
        for entry in registry {
            // Two processes on one session id (resume after a crash): keep the
            // most recently updated one.
            if let existing = registryBySession[entry.sessionId],
               (existing.updatedAt ?? 0) > (entry.updatedAt ?? 0) {
                continue
            }
            registryBySession[entry.sessionId] = entry
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
                now: now, activeThreshold: activeThreshold
            )
            agents.append(FleetAgent(
                summary: summary,
                registry: entry,
                state: derived.state,
                since: derived.since,
                isLive: isLive,
                isBackgroundJob: (entry?.isBackground ?? false) || summary.sessionKind == "bg",
                isBypass: summary.everBypassedPermissions == true
            ))
        }
        return agents.sorted {
            if $0.state.sortRank != $1.state.sortRank { return $0.state.sortRank < $1.state.sortRank }
            if $0.since != $1.since { return $0.since < $1.since }
            return $0.id < $1.id
        }
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
        return agents.reduce(0) { total, agent in
            total + agent.summary.dailyContributions.filter { $0.date == key }.reduce(0) { $0 + $1.estimatedCost }
        }
    }

    private static func nonEmpty(_ s: String) -> String? {
        s.isEmpty ? nil : s
    }
}

import Foundation

// MARK: - Hook Runtime Aggregate

/// Cross-session rollup of one hook command's runtime behavior, joined against
/// the currently configured hooks.
struct HookRuntimeAggregate: Sendable, Identifiable {
    var id: String { hookName + "|" + command }
    let hookName: String
    let command: String
    let sessionCount: Int
    let fireCount: Int
    let errorCount: Int
    let totalDurationMs: Int
    let maxDurationMs: Int
    /// False when the command appears in transcripts but matches no currently
    /// configured hook (deleted or renamed since those sessions ran).
    let isConfigured: Bool

    var avgDurationMs: Int { fireCount > 0 ? totalDurationMs / fireCount : 0 }
}

// MARK: - Hook Runtime Engine

/// Pure fold over SessionSummary.hookRunStats, in the AnalyticsEngine.compute
/// style: no store access, recomputed by SessionStore after session reloads.
enum HookRuntimeEngine {
    static func aggregate(
        sessions: [SessionSummary],
        hookGroups: [HookEventGroup]
    ) -> [HookRuntimeAggregate] {
        var acc: [String: (hookName: String, command: String, sessions: Int, fires: Int, errors: Int, totalMs: Int, maxMs: Int)] = [:]

        for session in sessions {
            guard let stats = session.hookRunStats else { continue }
            for cmd in stats.perCommand {
                var entry = acc[cmd.id] ?? (cmd.hookName, cmd.command, 0, 0, 0, 0, 0)
                entry.sessions += 1
                entry.fires += cmd.fireCount
                entry.errors += cmd.errorCount
                entry.totalMs += cmd.totalDurationMs
                entry.maxMs = max(entry.maxMs, cmd.maxDurationMs)
                acc[cmd.id] = entry
            }
        }

        let configuredCommands = Set(
            hookGroups.flatMap { $0.rules.flatMap { $0.hooks.map(\.command) } }
        )

        return acc.values
            .map { entry in
                HookRuntimeAggregate(
                    hookName: entry.hookName,
                    command: entry.command,
                    sessionCount: entry.sessions,
                    fireCount: entry.fires,
                    errorCount: entry.errors,
                    totalDurationMs: entry.totalMs,
                    maxDurationMs: entry.maxMs,
                    isConfigured: isConfigured(entry.command, in: configuredCommands)
                )
            }
            .sorted {
                if $0.fireCount != $1.fireCount { return $0.fireCount > $1.fireCount }
                return $0.id < $1.id
            }
    }

    /// Transcripts record expanded script paths while settings may hold
    /// shorthand (env-var prefixes, relative paths), so exact match first,
    /// then either string ending with the other.
    static func isConfigured(_ runtimeCommand: String, in configured: Set<String>) -> Bool {
        if runtimeCommand.isEmpty { return false }
        if configured.contains(runtimeCommand) { return true }
        return configured.contains { conf in
            !conf.isEmpty && (runtimeCommand.hasSuffix(conf) || conf.hasSuffix(runtimeCommand))
        }
    }
}

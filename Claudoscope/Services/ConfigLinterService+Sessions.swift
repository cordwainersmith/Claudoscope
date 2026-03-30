import Foundation

extension ConfigLinterService {

    // MARK: - Session Health Checks

    func lintSessions(_ sessions: [SessionSummary]) -> [LintResult] {
        let now = Date()
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -Self.sesLookbackDays, to: now)!

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let isoFormatterNoFrac = ISO8601DateFormatter()
        isoFormatterNoFrac.formatOptions = [.withInternetDateTime]

        func parseDate(_ str: String) -> Date? {
            isoFormatter.date(from: str) ?? isoFormatterNoFrac.date(from: str)
        }

        var results: [LintResult] = []

        for session in sessions {
            guard session.messageCount > 0 else { continue }
            guard let firstDate = parseDate(session.firstTimestamp), firstDate >= cutoff else { continue }

            let syntheticPath = "sessions/\(session.projectId)/\(session.id)"
            let displayTitle = String(session.title.prefix(60))
            let totalTokens = session.totalInputTokens + session.totalOutputTokens
                + session.totalCacheReadTokens + session.totalCacheCreationTokens
            // Skip sessions with 0 tokens - stale data from UUID dedup bug
            guard totalTokens > 0 else { continue }
            let statsTag = " [$\(String(format: "%.2f", session.estimatedCost)) | \(formatTokenCount(totalTokens)) tokens | \(session.messageCount) msgs]"

            // Priority order: SES001 > SES003 > SES002 > SES004 (emit only one per session)
            if session.estimatedCost > Self.sesHighCostThreshold {
                results.append(LintResult(
                    severity: .warning,
                    checkId: .SES001,
                    filePath: syntheticPath,
                    message: "Session cost $\(String(format: "%.2f", session.estimatedCost)). High-cost sessions often indicate context window saturation, where the model re-reads growing context on every turn, multiplying token spend." + statsTag,
                    fix: "For similar tasks, break work into focused sessions. Use /compact proactively before reaching 60% context utilization.",
                    displayPath: displayTitle
                ))
            } else if totalTokens > Self.sesHighTokenThreshold {
                results.append(LintResult(
                    severity: .warning,
                    checkId: .SES003,
                    filePath: syntheticPath,
                    message: "Session consumed \(formatTokenCount(totalTokens)) tokens. High cumulative token counts signal repeated context re-reads across compaction cycles, increasing cost without proportional value." + statsTag,
                    fix: "Start fresh sessions at natural boundaries (e.g., after finishing a feature). Periodic /compact reduces redundant context re-reads.",
                    displayPath: displayTitle
                ))
            } else if session.compactionCount >= Self.sesHighCompactionThreshold {
                results.append(LintResult(
                    severity: .warning,
                    checkId: .SES002,
                    filePath: syntheticPath,
                    message: "Session hit \(session.compactionCount) compaction cycles. Frequent compaction means the context window filled repeatedly, causing Claude to lose earlier decisions and instructions." + statsTag,
                    fix: "Break work into focused sessions at natural boundaries. Use /compact proactively before the context fills, or start a fresh session after each milestone.",
                    displayPath: displayTitle
                ))
            } else if let lastDate = parseDate(session.lastTimestamp),
                      session.messageCount > Self.sesStaleMinMessages {
                let daysSince = calendar.dateComponents([.day], from: lastDate, to: now).day ?? 0
                if daysSince > Self.sesStaleDaysThreshold {
                    results.append(LintResult(
                        severity: .info,
                        checkId: .SES004,
                        filePath: syntheticPath,
                        message: "Session idle for \(daysSince) days with \(session.messageCount) messages. Resuming a stale session means Claude rebuilds context from a compressed summary, losing nuance from the original conversation." + statsTag,
                        fix: "Start a fresh session rather than resuming. Use /clear or begin a new Claude Code instance for better results.",
                        displayPath: displayTitle
                    ))
                }
            }

            // SES005: Error pattern detection (independent of priority chain above)
            let errors = session.observability.errorClassifications
            if !errors.isEmpty {
                let errorLabels = errors.map(\.label).joined(separator: ", ")
                let severity: LintSeverity = errors.contains(where: { $0 == .rateLimit || $0 == .authFailure }) ? .error : .warning
                results.append(LintResult(
                    severity: severity,
                    checkId: .SES005,
                    filePath: syntheticPath,
                    message: "Session experienced \(errors.count) error type(s): \(errorLabels). Check API configuration and rate limits." + statsTag,
                    fix: errors.contains(.rateLimit) ? "Consider adding request throttling or upgrading API tier" : "Review session logs for error details",
                    displayPath: displayTitle
                ))
            }

            // SES006: Idle/zombie session detection
            if session.observability.hasIdleZombieGap {
                let wasteCost = session.observability.estimatedIdleWasteCost
                let costNote = wasteCost > 0 ? String(format: " (estimated $%.2f re-cache waste)", wasteCost) : ""
                results.append(LintResult(
                    severity: .warning,
                    checkId: .SES006,
                    filePath: syntheticPath,
                    message: "Session resumed after 75+ minute idle gap without /clear\(costNote). Stale context forces full re-caching." + statsTag,
                    fix: "Use /clear when returning to a session after extended breaks",
                    displayPath: displayTitle
                ))
            }
        }

        // Sort by severity (errors first, then warnings, then info), cap at 10
        results.sort { $0.severity < $1.severity }
        if results.count > Self.sesMaxResults {
            results = Array(results.prefix(Self.sesMaxResults))
        }

        return results
    }
}

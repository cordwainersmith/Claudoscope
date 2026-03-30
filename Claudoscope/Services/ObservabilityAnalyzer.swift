import Foundation

/// Stateless analyzer for session observability metrics.
/// All methods are pure functions that take input data and return computed results.
struct ObservabilityAnalyzer {

    // MARK: - Threshold Constants

    static let thinkingCharsMedium = 1000
    static let thinkingCharsHigh = 5000
    static let outputTokensMedium = 500
    static let outputTokensHigh = 2000
    static let idleGapThresholdMinutes = 75

    // MARK: - Effort Classification

    static func classifyEffort(thinkingChars: Int, outputTokens: Int, stopReason: String?) -> EffortLevel {
        if stopReason == "max_tokens" {
            return .ultrathink
        }
        if thinkingChars >= thinkingCharsHigh || outputTokens >= outputTokensHigh {
            return .ultrathink
        }
        if thinkingChars >= thinkingCharsMedium || outputTokens >= outputTokensMedium {
            return .high
        }
        if thinkingChars > 0 || outputTokens > 0 {
            return .medium
        }
        return .low
    }

    // MARK: - Error Classification

    static func classifyError(contentText: String, stopReason: String?) -> ErrorClassification {
        let lower = contentText.lowercased()

        if lower.contains("rate limit") || lower.contains("429") || lower.contains("too many requests") {
            return .rateLimit
        }
        if lower.contains("401") || lower.contains("unauthorized") || lower.contains("authentication") {
            return .authFailure
        }
        if lower.contains("proxy") || lower.contains("502") || lower.contains("503") || lower.contains("gateway") {
            return .proxyError
        }
        if stopReason == "max_tokens" {
            return .maxTokensTruncation
        }
        return .unknown
    }

    // MARK: - Turn Duration Computation

    static func computeTurnDurations(records: [ParsedRecordRaw]) -> [TurnDuration] {
        var durations: [TurnDuration] = []
        var lastUserTimestamp: String?
        var turnIndex = 0
        var hadCompaction = false

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let formatterNoFrac = ISO8601DateFormatter()
        formatterNoFrac.formatOptions = [.withInternetDateTime]

        for record in records {
            if record.type == .user {
                lastUserTimestamp = record.timestamp
            }

            if record.type == .system && record.subtype == "compact_boundary" {
                hadCompaction = true
            }

            if record.type == .assistant, record.message?.stopReason != nil {
                let assistantTs = record.timestamp
                var durationMs: Double = 0

                if let userTs = lastUserTimestamp, let aTs = assistantTs {
                    if let userDate = parseISO8601(userTs, formatter: formatter, fallback: formatterNoFrac),
                       let assistantDate = parseISO8601(aTs, formatter: formatter, fallback: formatterNoFrac) {
                        durationMs = assistantDate.timeIntervalSince(userDate) * 1000
                        // Clamp negative durations (clock skew) to zero
                        if durationMs < 0 { durationMs = 0 }
                    }
                }

                let inputTokens = record.message?.usage?.inputTokens ?? 0
                durations.append(TurnDuration(
                    turnIndex: turnIndex,
                    userTimestamp: lastUserTimestamp,
                    assistantTimestamp: assistantTs,
                    durationMs: durationMs,
                    isPostCompaction: hadCompaction,
                    inputTokens: inputTokens,
                    model: record.message?.model
                ))

                turnIndex += 1
                lastUserTimestamp = nil
            }
        }

        return durations
    }

    // MARK: - Idle Gap Detection

    struct IdleGapResult: Sendable {
        let maxGapSeconds: Double
        let gapTimestamp: String?
        let hasZombieGap: Bool
    }

    static func detectIdleGaps(
        records: [ParsedRecordRaw],
        thresholdMinutes: Int = idleGapThresholdMinutes
    ) -> IdleGapResult {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let formatterNoFrac = ISO8601DateFormatter()
        formatterNoFrac.formatOptions = [.withInternetDateTime]

        var timestamps: [(ts: String, date: Date, index: Int)] = []

        for (i, record) in records.enumerated() {
            if let ts = record.timestamp,
               let date = parseISO8601(ts, formatter: formatter, fallback: formatterNoFrac) {
                timestamps.append((ts: ts, date: date, index: i))
            }
        }

        guard timestamps.count >= 2 else {
            return IdleGapResult(maxGapSeconds: 0, gapTimestamp: nil, hasZombieGap: false)
        }

        var maxGap: Double = 0
        var maxGapTimestamp: String?
        var maxGapIndex = 0

        for i in 1..<timestamps.count {
            let gap = timestamps[i].date.timeIntervalSince(timestamps[i - 1].date)
            if gap > maxGap {
                maxGap = gap
                maxGapTimestamp = timestamps[i - 1].ts
                maxGapIndex = i
            }
        }

        let thresholdSeconds = Double(thresholdMinutes) * 60
        let hasZombie = maxGap > thresholdSeconds && maxGapIndex < timestamps.count - 1

        return IdleGapResult(
            maxGapSeconds: maxGap,
            gapTimestamp: maxGapTimestamp,
            hasZombieGap: hasZombie
        )
    }

    // MARK: - Compute Session Observability

    static func computeObservability(
        turnDurations: [TurnDuration],
        effortCounts: [EffortLevel: Int],
        errorDetails: [SessionErrorDetail],
        idleGapResult: IdleGapResult,
        compactionEvents: [CompactionEvent],
        parallelToolGroups: [ParallelToolGroup]
    ) -> SessionObservability {
        // Median and max turn duration
        let validDurations = turnDurations.filter { $0.durationMs > 0 }
        let medianMs: Double?
        let maxMs: Double?

        if validDurations.isEmpty {
            medianMs = nil
            maxMs = nil
        } else {
            let sorted = validDurations.map(\.durationMs).sorted()
            maxMs = sorted.last
            let mid = sorted.count / 2
            if sorted.count % 2 == 0 {
                medianMs = (sorted[mid - 1] + sorted[mid]) / 2.0
            } else {
                medianMs = sorted[mid]
            }
        }

        // Effort distribution
        let distribution = EffortDistribution(
            low: effortCounts[.low, default: 0],
            medium: effortCounts[.medium, default: 0],
            high: effortCounts[.high, default: 0],
            ultrathink: effortCounts[.ultrathink, default: 0]
        )

        // Dominant effort level (most frequent)
        let dominant: EffortLevel?
        if distribution.total > 0 {
            let levels: [(EffortLevel, Int)] = [
                (.low, distribution.low),
                (.medium, distribution.medium),
                (.high, distribution.high),
                (.ultrathink, distribution.ultrathink),
            ]
            dominant = levels.max(by: { $0.1 < $1.1 })?.0
        } else {
            dominant = nil
        }

        // Error classifications (unique)
        let errorClassifications = Array(Set(errorDetails.map(\.classification)))

        // Compaction timestamps
        let compactionTimestamps = compactionEvents.compactMap(\.timestamp)

        // Parallel tool call stats
        let parallelToolCallCount = parallelToolGroups.count
        let maxParallelDegree = parallelToolGroups.map(\.toolCount).max() ?? 0

        return SessionObservability(
            medianTurnDurationMs: medianMs,
            maxTurnDurationMs: maxMs,
            dominantEffortLevel: dominant,
            effortDistribution: distribution,
            errorClassifications: errorClassifications,
            hasIdleZombieGap: idleGapResult.hasZombieGap,
            estimatedIdleWasteCost: 0,
            compactionTimestamps: compactionTimestamps,
            parallelToolCallCount: parallelToolCallCount,
            maxParallelDegree: maxParallelDegree
        )
    }

    // MARK: - Subagent Tree

    static func buildSubagentTree(
        parentSession: SessionSummary,
        subagentSummaries: [SessionSummary]
    ) -> SubagentNode {
        let children = subagentSummaries.map { sub in
            SubagentNode(
                id: sub.id,
                sessionTitle: sub.title,
                model: sub.primaryModel,
                totalInputTokens: sub.totalInputTokens,
                totalOutputTokens: sub.totalOutputTokens,
                estimatedCost: sub.estimatedCost,
                toolCallCount: sub.toolCallCount,
                messageCount: sub.messageCount,
                children: []
            )
        }

        return SubagentNode(
            id: parentSession.id,
            sessionTitle: parentSession.title,
            model: parentSession.primaryModel,
            totalInputTokens: parentSession.totalInputTokens,
            totalOutputTokens: parentSession.totalOutputTokens,
            estimatedCost: parentSession.estimatedCost,
            toolCallCount: parentSession.toolCallCount,
            messageCount: parentSession.messageCount,
            children: children
        )
    }

    // MARK: - ISO8601 Parsing Helper

    private static func parseISO8601(
        _ string: String,
        formatter: ISO8601DateFormatter,
        fallback: ISO8601DateFormatter
    ) -> Date? {
        formatter.date(from: string) ?? fallback.date(from: string)
    }
}

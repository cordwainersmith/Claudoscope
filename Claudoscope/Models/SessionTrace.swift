import Foundation

/// The session laid out on a time axis: every lane the Trace tab draws, plus
/// the idle gaps it may collapse. Built once per parsed session by a pure
/// function so the view only maps dates to pixels.
struct SessionTrace: Sendable, Equatable {
    struct UserTurn: Sendable, Equatable {
        let turnNumber: Int
        let recordIndex: Int
        let uuid: String?
        let time: Date
        let label: String
    }

    /// Claude working on one user turn: from the prompt to the last assistant
    /// record or tool result before the next prompt.
    struct ClaudeSpan: Sendable, Equatable {
        let turnNumber: Int
        let recordIndex: Int
        let uuid: String?
        let start: Date
        let end: Date
        let toolCallCount: Int
    }

    struct ToolCall: Sendable, Equatable {
        let recordIndex: Int
        let uuid: String?
        let time: Date
        let name: String
        let category: ToolCategory
        let label: String
        let isError: Bool
        let isBlocked: Bool
    }

    struct AgentSpan: Sendable, Equatable {
        let recordIndex: Int
        let uuid: String?
        let start: Date
        /// Nil while the agent is still running (no tool result yet).
        let end: Date?
        let label: String
        /// Stacking row so concurrent agents do not overlap.
        let row: Int
    }

    struct Compaction: Sendable, Equatable {
        let recordIndex: Int
        let uuid: String?
        let time: Date
    }

    struct ContextPoint: Sendable, Equatable {
        let time: Date
        let utilization: Double
        let tokens: Int
    }

    struct CostPoint: Sendable, Equatable {
        let time: Date
        let cumulative: Double
    }

    struct Gap: Sendable, Equatable {
        let start: Date
        let end: Date
        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    let start: Date
    let end: Date
    let userTurns: [UserTurn]
    let claudeSpans: [ClaudeSpan]
    let toolCalls: [ToolCall]
    let agentSpans: [AgentSpan]
    let compactions: [Compaction]
    let contextPoints: [ContextPoint]
    let costPoints: [CostPoint]
    let gaps: [Gap]
    let models: [String]

    var totalCost: Double { costPoints.last?.cumulative ?? 0 }
    var agentRowCount: Int { (agentSpans.map(\.row).max() ?? -1) + 1 }
    var duration: TimeInterval { end.timeIntervalSince(start) }
    var activeDuration: TimeInterval { duration - gaps.reduce(0) { $0 + $1.duration } }

    /// Idle stretches at least this long are reported as gaps.
    static let gapThreshold: TimeInterval = 5 * 60

    // MARK: - Build

    /// `blockedToolUseIds` come from `ObservabilityAnalyzer.extractBlockedActions`,
    /// the same source the minimap uses. Returns nil when the session has no
    /// timestamped turn at all.
    static func build(
        for session: ParsedSession,
        blockedToolUseIds: Set<String>,
        pricingTable: [String: ModelPricing]
    ) -> SessionTrace? {
        let records = session.records
        var userTurns: [UserTurn] = []
        var toolCalls: [ToolCall] = []
        var agentSpans: [AgentSpan] = []
        var compactions: [Compaction] = []
        var costPoints: [CostPoint] = []
        var models: [String] = []
        var seenMessageIds: Set<String> = []
        var cumulativeCost = 0.0

        // Per-turn bookkeeping for Claude spans.
        struct OpenTurn {
            let turnNumber: Int
            let recordIndex: Int
            let uuid: String?
            let start: Date
            var lastActivity: Date
            var toolCallCount: Int
        }
        var claudeSpans: [ClaudeSpan] = []
        var openTurn: OpenTurn?

        func closeTurn() {
            guard let turn = openTurn else { return }
            if turn.lastActivity > turn.start {
                claudeSpans.append(ClaudeSpan(
                    turnNumber: turn.turnNumber, recordIndex: turn.recordIndex, uuid: turn.uuid,
                    start: turn.start, end: turn.lastActivity, toolCallCount: turn.toolCallCount
                ))
            }
            openTurn = nil
        }

        for (index, record) in records.enumerated() {
            guard let ts = record.timestamp, let time = ISO8601.parse(ts) else { continue }
            switch record.type {
            case .user:
                let text = strippedUserText(record.message?.content?.textContent)
                if text.isEmpty {
                    // Tool results ride on user records; they extend the current turn.
                    if var turn = openTurn { turn.lastActivity = max(turn.lastActivity, time); openTurn = turn }
                    continue
                }
                closeTurn()
                let turnNumber = userTurns.count + 1
                userTurns.append(UserTurn(
                    turnNumber: turnNumber, recordIndex: index, uuid: record.uuid,
                    time: time, label: String(text.prefix(80))
                ))
                openTurn = OpenTurn(
                    turnNumber: turnNumber, recordIndex: index, uuid: record.uuid,
                    start: time, lastActivity: time, toolCallCount: 0
                )

            case .assistant:
                if var turn = openTurn { turn.lastActivity = max(turn.lastActivity, time); openTurn = turn }
                guard let message = record.message else { continue }
                if let model = message.model, !models.contains(model) { models.append(model) }

                if message.stopReason != nil, let usage = message.usage {
                    let isNew = message.id.map { seenMessageIds.insert($0).inserted } ?? true
                    if isNew {
                        cumulativeCost += Self.messageCost(
                            model: message.model, usage: usage, timestamp: ts, table: pricingTable
                        )
                        costPoints.append(CostPoint(time: time, cumulative: cumulativeCost))
                    }
                }

                guard case .blocks(let blocks) = message.content else { continue }
                for block in blocks where block.type == "tool_use" {
                    guard let name = block.name else { continue }
                    let input = block.input ?? [:]
                    let arg = primaryArgument(from: input, toolName: name)
                    let label = arg.map { "\(name): \($0)" } ?? name
                    let result = block.id.flatMap { session.toolResultMap[$0] }
                    let isBlocked = block.id.map(blockedToolUseIds.contains) ?? false
                    toolCalls.append(ToolCall(
                        recordIndex: index, uuid: record.uuid, time: time, name: name,
                        category: toolCategory(for: name), label: label,
                        isError: !isBlocked && result?.isError == true, isBlocked: isBlocked
                    ))
                    if var turn = openTurn {
                        turn.toolCallCount += 1
                        if let resultTime = result?.timestamp.flatMap(ISO8601.parse) {
                            turn.lastActivity = max(turn.lastActivity, resultTime)
                        }
                        openTurn = turn
                    }
                    if name == "Agent" {
                        let description = input["description"]?.stringValue ?? "subagent"
                        agentSpans.append(AgentSpan(
                            recordIndex: index, uuid: record.uuid, start: time,
                            end: result?.timestamp.flatMap(ISO8601.parse),
                            label: description, row: 0
                        ))
                    }
                }

            case .system:
                if record.subtype == "compact_boundary" {
                    compactions.append(Compaction(recordIndex: index, uuid: record.uuid, time: time))
                }

            default:
                continue
            }
        }
        closeTurn()

        let contextPoints = ContextPressurePoint.series(for: records).compactMap { point -> ContextPoint? in
            guard let time = ISO8601.parse(point.timestamp) else { return nil }
            return ContextPoint(time: time, utilization: point.utilization, tokens: point.contextTokens)
        }

        var times = userTurns.map(\.time) + toolCalls.map(\.time) + compactions.map(\.time)
        times += claudeSpans.map(\.end) + costPoints.map(\.time)
        guard let start = times.min(), let end = times.max() else { return nil }

        let stackedAgents = stackAgents(agentSpans, fallbackEnd: end)
        let busy = claudeSpans.map { ($0.start, $0.end) }
            + stackedAgents.map { ($0.start, $0.end ?? end) }
            + times.map { ($0, $0) }

        return SessionTrace(
            start: start, end: end,
            userTurns: userTurns, claudeSpans: claudeSpans, toolCalls: toolCalls,
            agentSpans: stackedAgents, compactions: compactions,
            contextPoints: contextPoints, costPoints: costPoints,
            gaps: gaps(between: busy), models: models
        )
    }

    /// Same per-message cost the parser bills, minus the orphan-stream pass:
    /// the trace is a picture, and an aborted stream's partial usage is not
    /// worth a second scan here.
    private static func messageCost(
        model: String?, usage: TokenUsageRaw, timestamp: String, table: [String: ModelPricing]
    ) -> Double {
        let cacheCreate = usage.cacheCreationInputTokens ?? 0
        let breakdown5m = usage.cacheCreation?.ephemeral5mInputTokens
        let breakdown1h = usage.cacheCreation?.ephemeral1hInputTokens
        let cache5m: Int
        let cache1h: Int
        if breakdown5m != nil || breakdown1h != nil {
            cache5m = breakdown5m ?? 0
            cache1h = breakdown1h ?? 0
        } else {
            cache5m = cacheCreate
            cache1h = 0
        }
        let isFast = usage.speed != nil && usage.speed != "standard"
        return estimateCostFromTokens(
            model: model,
            inputTokens: usage.inputTokens ?? 0,
            outputTokens: usage.outputTokens ?? 0,
            cacheReadTokens: usage.cacheReadInputTokens ?? 0,
            cacheCreation5mTokens: cache5m,
            cacheCreation1hTokens: cache1h,
            table: table,
            on: ISO8601.localDayKey(timestamp) ?? "1970-01-01",
            speedMultiplier: isFast ? fastModeRateMultiplier : 1.0
        )
    }

    /// Greedy interval stacking: an agent takes the lowest row whose previous
    /// occupant finished before it started.
    static func stackAgents(_ spans: [AgentSpan], fallbackEnd: Date) -> [AgentSpan] {
        var rowEnds: [Date] = []
        return spans.sorted { $0.start < $1.start }.map { span in
            let spanEnd = span.end ?? fallbackEnd
            let row = rowEnds.firstIndex { $0 <= span.start } ?? rowEnds.count
            if row == rowEnds.count { rowEnds.append(spanEnd) } else { rowEnds[row] = spanEnd }
            return AgentSpan(
                recordIndex: span.recordIndex, uuid: span.uuid, start: span.start,
                end: span.end, label: span.label, row: row
            )
        }
    }

    /// Idle stretches between busy intervals (spans and point events) longer
    /// than `gapThreshold`. A long-running tool inside a Claude span is busy,
    /// so a ten-minute build does not collapse.
    static func gaps(between intervals: [(Date, Date)]) -> [Gap] {
        let sorted = intervals.sorted { $0.0 < $1.0 }
        guard var cursor = sorted.first?.1 else { return [] }
        var gaps: [Gap] = []
        for (start, end) in sorted.dropFirst() {
            if start.timeIntervalSince(cursor) >= gapThreshold {
                gaps.append(Gap(start: cursor, end: start))
            }
            cursor = max(cursor, end)
        }
        return gaps
    }

    // MARK: - Hover helpers

    /// Cumulative cost at a moment: the last cost point at or before it.
    func cost(at time: Date) -> Double {
        var value = 0.0
        for point in costPoints {
            if point.time > time { break }
            value = point.cumulative
        }
        return value
    }

    /// Context occupancy at a moment: the last context point at or before it.
    func contextUtilization(at time: Date) -> Double? {
        var value: Double?
        for point in contextPoints {
            if point.time > time { break }
            value = point.utilization
        }
        return value
    }

    /// The user turn in progress at a moment.
    func turn(at time: Date) -> UserTurn? {
        var current: UserTurn?
        for turn in userTurns {
            if turn.time > time { break }
            current = turn
        }
        return current
    }
}

/// Maps dates to a 0...1 fraction, optionally collapsing idle gaps so a
/// session that spans two days still fits one screen. Each collapsed gap keeps
/// a fixed virtual width so the break stays visible and clickable.
struct TraceTimeAxis: Sendable, Equatable {
    let start: Date
    let end: Date
    let gaps: [SessionTrace.Gap]
    let collapsesGaps: Bool

    static let collapsedGapSeconds: TimeInterval = 30

    init(trace: SessionTrace, collapsesGaps: Bool) {
        start = trace.start
        end = trace.end
        gaps = collapsesGaps ? trace.gaps : []
        self.collapsesGaps = collapsesGaps
    }

    var virtualDuration: TimeInterval {
        let removed = gaps.reduce(0) { $0 + ($1.duration - Self.collapsedGapSeconds) }
        return max(end.timeIntervalSince(start) - removed, 1)
    }

    /// Seconds along the compressed axis.
    func virtualOffset(of date: Date) -> TimeInterval {
        var offset = date.timeIntervalSince(start)
        for gap in gaps {
            if date >= gap.end {
                offset -= gap.duration - Self.collapsedGapSeconds
            } else if date > gap.start {
                let inside = date.timeIntervalSince(gap.start) / gap.duration
                offset -= date.timeIntervalSince(gap.start) - inside * Self.collapsedGapSeconds
                break
            } else {
                break
            }
        }
        return offset
    }

    func fraction(of date: Date) -> Double {
        min(max(virtualOffset(of: date) / virtualDuration, 0), 1)
    }

    /// Inverse of `fraction(of:)`, used for hover and the replay playhead.
    func date(atFraction fraction: Double) -> Date {
        var remaining = min(max(fraction, 0), 1) * virtualDuration
        var cursor = start
        for gap in gaps {
            let before = gap.start.timeIntervalSince(cursor)
            if remaining <= before { return cursor.addingTimeInterval(remaining) }
            remaining -= before
            if remaining <= Self.collapsedGapSeconds {
                return gap.start.addingTimeInterval(remaining / Self.collapsedGapSeconds * gap.duration)
            }
            remaining -= Self.collapsedGapSeconds
            cursor = gap.end
        }
        return cursor.addingTimeInterval(remaining)
    }

    /// Fraction range each collapsed gap occupies, for drawing break markers.
    var gapFractions: [(gap: SessionTrace.Gap, range: ClosedRange<Double>)] {
        gaps.map { ($0, fraction(of: $0.start)...fraction(of: $0.end)) }
    }
}

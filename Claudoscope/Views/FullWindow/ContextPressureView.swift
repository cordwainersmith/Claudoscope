import SwiftUI
import Charts

/// How full the context window got over the course of a session, with compaction
/// events marked. Answers the question the cost charts can't: whether a session was
/// running out of room, and whether compaction bought it any.
struct ContextPressureView: View {
    private let points: [ContextPressurePoint]
    private let compactionTimestamps: [String]
    private let mixedTokenizers: Bool

    /// The series is computed once here rather than in a body-level computed
    /// property: it walks every record, and a view body re-evaluates constantly.
    init(session: ParsedSession) {
        let points = ContextPressurePoint.series(for: session.records)
        self.points = points
        self.compactionTimestamps = session.metadata.compactionEvents.compactMap(\.timestamp)
        self.mixedTokenizers = Self.hasMixedTokenizers(session.metadata.models)
    }

    private var peak: ContextPressurePoint? {
        points.max(by: { $0.utilization < $1.utilization })
    }

    private var windowTokens: Int {
        points.last?.windowTokens ?? ContextWindow.extended
    }

    var body: some View {
        if points.isEmpty {
            EmptyStateView(
                icon: "gauge.with.dots.needle.33percent",
                title: "No context data",
                message: "This session has no billed assistant turns to measure."
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    statCards
                    chart
                    if mixedTokenizers { tokenizerCaveat }
                }
                .padding(24)
            }
        }
    }

    private var statCards: some View {
        HStack(spacing: 12) {
            StatCard(
                title: "Peak Context",
                value: formatTokens(peak?.contextTokens ?? 0),
                subtitle: "of \(formatTokens(windowTokens)) window"
            )
            StatCard(
                title: "Peak Utilization",
                value: String(format: "%.0f%%", (peak?.utilization ?? 0) * 100),
                isHighlighted: (peak?.utilization ?? 0) > 0.8
            )
            .help("Above 80% a turn is close enough to the ceiling that auto-compact is likely to fire mid-task.")
            StatCard(
                title: "Compactions",
                value: "\(compactionTimestamps.count)"
            )
            .help("Each compaction rewrites the conversation to reclaim room. Frequent compaction means work is being summarized away.")
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Context used per turn")
                .font(Typography.body)

            Chart {
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    AreaMark(
                        x: .value("Turn", index),
                        y: .value("Tokens", point.contextTokens)
                    )
                    .foregroundStyle(Color.scaleLow.opacity(0.2))
                    .interpolationMethod(.monotone)

                    LineMark(
                        x: .value("Turn", index),
                        y: .value("Tokens", point.contextTokens)
                    )
                    .foregroundStyle(Color.scaleMedium)
                    .interpolationMethod(.monotone)
                }

                RuleMark(y: .value("Window", windowTokens))
                    .foregroundStyle(Color.scaleMax.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("\(formatTokens(windowTokens)) window")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.scaleMax)
                    }

                ForEach(compactionIndices, id: \.self) { index in
                    RuleMark(x: .value("Turn", index))
                        .foregroundStyle(Color.scaleHigh.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                        .annotation(position: .bottom, alignment: .center) {
                            Text("compact")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Color.scaleHigh)
                        }
                }
            }
            .chartYScale(domain: 0...max(windowTokens, peak?.contextTokens ?? 0))
            .chartXAxisLabel("Assistant turn")
            .frame(height: 220)
        }
    }

    /// Compactions are timestamped; the chart is indexed by turn. Map each one onto
    /// the first turn at or after it so the marker lands where the drop shows.
    private var compactionIndices: [Int] {
        compactionTimestamps.compactMap { ts in
            points.firstIndex { $0.timestamp >= ts }
        }
    }

    private var tokenizerCaveat: some View {
        Text("This session mixes model generations that tokenize differently: Claude 4.7 and later produce roughly 30% more tokens for the same text. Turn-to-turn changes across that boundary are not like-for-like.")
            .font(Typography.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Claude 4.7 introduced a new tokenizer. Comparing token counts across that
    /// line overstates growth, so say so rather than let the chart imply it.
    private static func hasMixedTokenizers(_ models: [String]) -> Bool {
        let older = ["opus-4-5", "opus-4-6", "sonnet-4-5", "sonnet-4-6", "haiku-4-5", "claude-3"]
        let hasOlder = models.contains { model in
            let m = model.lowercased()
            return older.contains { m.contains($0) }
        }
        let hasNewer = models.contains { model in
            let m = model.lowercased()
            return !older.contains { m.contains($0) }
        }
        return hasOlder && hasNewer
    }
}

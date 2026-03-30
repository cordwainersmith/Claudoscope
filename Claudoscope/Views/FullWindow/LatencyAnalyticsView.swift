import SwiftUI
import Charts

struct LatencyAnalyticsView: View {
    let data: LatencyAnalytics

    var body: some View {
        if data.histogram.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "clock")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("No Latency Data")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Turn duration data will appear once sessions are analyzed.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Percentile stat cards
                    HStack(spacing: 12) {
                        StatCard(title: "Median (p50)", value: formatMs(data.medianDurationMs))
                        StatCard(title: "p95", value: formatMs(data.p95DurationMs))
                        StatCard(title: "p99", value: formatMs(data.p99DurationMs))
                    }
                    .padding(.horizontal, 24)

                    // Histogram
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Turn Duration Distribution")
                            .font(.headline)
                        Chart(data.histogram) { bucket in
                            BarMark(
                                x: .value("Duration", bucket.label),
                                y: .value("Sessions", bucket.count)
                            )
                            .foregroundStyle(.blue.gradient)
                        }
                        .frame(height: 200)
                    }
                    .padding(.horizontal, 24)

                    // Compaction correlation
                    if data.postCompactionAvgMs > 0 || data.normalAvgMs > 0 {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Compaction Impact")
                                .font(.headline)
                            HStack(spacing: 12) {
                                StatCard(title: "Post-Compaction Avg", value: formatMs(data.postCompactionAvgMs))
                                StatCard(title: "Normal Avg", value: formatMs(data.normalAvgMs))
                            }
                        }
                        .padding(.horizontal, 24)
                    }

                    // Slowest turns table
                    if !data.slowestTurns.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Slowest Turns")
                                .font(.headline)
                            ForEach(data.slowestTurns) { turn in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(turn.sessionTitle)
                                            .font(.system(size: 13))
                                            .lineLimit(1)
                                        Text("Turn \(turn.turnIndex)")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if turn.isPostCompaction {
                                        Text("post-compaction")
                                            .font(.system(size: 10))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(.orange.opacity(0.1))
                                            .clipShape(Capsule())
                                    }
                                    Text(formatMs(turn.durationMs))
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundStyle(.red)
                                }
                                .padding(.vertical, 4)
                                Divider()
                            }
                        }
                        .padding(.horizontal, 24)
                    }

                    // Degrading sessions
                    if !data.degradingSessionIds.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Degrading Sessions")
                                .font(.headline)
                            Text("\(data.degradingSessionIds.count) session(s) with turns exceeding 60 seconds")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 24)
                    }
                }
                .padding(.vertical, 24)
            }
        }
    }

    private func formatMs(_ ms: Double) -> String {
        if ms < 1000 { return String(format: "%.0fms", ms) }
        if ms < 60000 { return String(format: "%.1fs", ms / 1000) }
        let min = Int(ms / 60000)
        let sec = Int(ms.truncatingRemainder(dividingBy: 60000) / 1000)
        return "\(min)m \(sec)s"
    }
}

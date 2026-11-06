import SwiftUI
import Charts

struct EffortAnalyticsView: View {
    let data: EffortAnalytics

    var body: some View {
        if data.distribution.total == 0 {
            VStack(spacing: 12) {
                Image(systemName: "brain")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("No Effort Data")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Effort level data will appear once sessions are analyzed.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Donut chart
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Effort Distribution")
                            .font(.headline)
                        Chart(EffortLevel.allCases, id: \.self) { level in
                            SectorMark(angle: .value(level.label, data.distribution.count(level)), innerRadius: .ratio(0.5), angularInset: 1.5)
                                .foregroundStyle(Color.forEffort(level))
                        }
                        .frame(height: 200)

                        HStack(spacing: 16) {
                            ForEach(EffortLevel.allCases, id: \.self) { level in
                                effortLegend(level.label, color: Color.forEffort(level), count: data.distribution.count(level))
                            }
                        }

                        if data.distribution.estimatedTurns > 0, data.distribution.total > 0 {
                            let pct = Int((Double(data.distribution.estimatedTurns) / Double(data.distribution.total) * 100).rounded())
                            Text("\(max(pct, 1))% of turns come from transcripts that predate recorded effort; their level is estimated from thinking length and output size.")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 24)

                    // Cost by effort table
                    if !data.costByEffort.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Cost by Effort Level")
                                .font(.headline)
                            ForEach(data.costByEffort) { row in
                                HStack {
                                    Circle()
                                        .fill(colorForEffort(row.level))
                                        .frame(width: 8, height: 8)
                                    Text(row.level.label)
                                        .font(.system(size: 13))
                                        .frame(width: 80, alignment: .leading)
                                    Text("\(row.turnCount) turns")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 80)
                                    if let ms = row.avgThinkingMs {
                                        Text(String(format: "%.1fs thinking", ms / 1000))
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(String(format: "$%.2f", row.totalCost))
                                        .font(.system(size: 13, design: .monospaced))
                                    Text(String(format: "($%.2f/turn)", row.avgCostPerTurn))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .padding(.horizontal, 24)
                    }

                    // Effort over time
                    if !data.effortOverTime.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Effort Over Time")
                                .font(.headline)
                            Chart(data.effortOverTime) { day in
                                ForEach(EffortLevel.allCases, id: \.self) { level in
                                    AreaMark(x: .value("Date", day.date), y: .value(level.label, day.distribution.count(level)))
                                        .foregroundStyle(Color.forEffort(level).opacity(0.7))
                                }
                            }
                            .stridedDateXAxis(dates: data.effortOverTime.map(\.date))
                            .frame(height: 200)
                        }
                        .padding(.horizontal, 24)
                    }
                }
                .padding(.vertical, 24)
            }
        }
    }

    @ViewBuilder
    private func effortLegend(_ label: String, color: Color, count: Int) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(label): \(count)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func colorForEffort(_ level: EffortLevel) -> Color {
        Color.forEffort(level)
    }
}

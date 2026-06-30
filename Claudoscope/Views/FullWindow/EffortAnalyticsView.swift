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
                        Chart {
                            SectorMark(angle: .value("Low", data.distribution.low), innerRadius: .ratio(0.5), angularInset: 1.5)
                                .foregroundStyle(Color.scaleLow)
                            SectorMark(angle: .value("Medium", data.distribution.medium), innerRadius: .ratio(0.5), angularInset: 1.5)
                                .foregroundStyle(Color.scaleMedium)
                            SectorMark(angle: .value("High", data.distribution.high), innerRadius: .ratio(0.5), angularInset: 1.5)
                                .foregroundStyle(Color.scaleHigh)
                            SectorMark(angle: .value("Ultra-think", data.distribution.ultrathink), innerRadius: .ratio(0.5), angularInset: 1.5)
                                .foregroundStyle(Color.scaleMax)
                        }
                        .frame(height: 200)

                        // Legend
                        HStack(spacing: 16) {
                            effortLegend("Low", color: .scaleLow, count: data.distribution.low)
                            effortLegend("Medium", color: .scaleMedium, count: data.distribution.medium)
                            effortLegend("High", color: .scaleHigh, count: data.distribution.high)
                            effortLegend("Ultra-think", color: .scaleMax, count: data.distribution.ultrathink)
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
                                AreaMark(x: .value("Date", day.date), y: .value("Low", day.distribution.low))
                                    .foregroundStyle(Color.scaleLow.opacity(0.7))
                                AreaMark(x: .value("Date", day.date), y: .value("Medium", day.distribution.medium))
                                    .foregroundStyle(Color.scaleMedium.opacity(0.7))
                                AreaMark(x: .value("Date", day.date), y: .value("High", day.distribution.high))
                                    .foregroundStyle(Color.scaleHigh.opacity(0.7))
                                AreaMark(x: .value("Date", day.date), y: .value("Ultra-think", day.distribution.ultrathink))
                                    .foregroundStyle(Color.scaleMax.opacity(0.7))
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
        switch level {
        case .low: return .scaleLow
        case .medium: return .scaleMedium
        case .high: return .scaleHigh
        case .ultrathink: return .scaleMax
        }
    }
}

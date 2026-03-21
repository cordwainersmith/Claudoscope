import SwiftUI
import Charts

struct ModelAnalysisView: View {
    @Environment(SessionStore.self) private var store
    @State private var outputThreshold: Int = 200

    private var data: AnalyticsData { store.analyticsData }

    private var whatIfSavings: WhatIfSavings {
        AnalyticsEngine.computeWhatIfSavings(
            sessions: store.allSessionsWithProjects,
            pricingTable: store.pricingTable,
            outputThreshold: outputThreshold
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Daily cost by model chart
                if !data.dailyModelCost.isEmpty {
                    DailyModelCostChartView(dailyModelCost: data.dailyModelCost)
                        .padding(.horizontal, 24)
                }

                // Model efficiency table
                if !data.modelEfficiency.isEmpty {
                    ModelEfficiencyTableView(rows: data.modelEfficiency)
                        .padding(.horizontal, 24)
                }

                // What-if calculator
                WhatIfCalculatorView(
                    threshold: $outputThreshold,
                    savings: whatIfSavings
                )
                .padding(.horizontal, 24)
            }
            .padding(.vertical, 24)
        }
    }
}

// MARK: - Daily Model Cost Chart

private struct DailyModelCostChartView: View {
    let dailyModelCost: [DailyModelCost]
    @State private var hoveredDate: String?

    private func colorForModel(_ model: String) -> Color {
        let lowered = model.lowercased()
        if lowered.contains("opus") { return .purple.opacity(0.7) }
        if lowered.contains("sonnet") { return .blue.opacity(0.7) }
        if lowered.contains("haiku") { return .green.opacity(0.7) }
        return .gray.opacity(0.7)
    }

    private var modelNames: [String] {
        Array(Set(dailyModelCost.map(\.model))).sorted()
    }

    private var colorMapping: KeyValuePairs<String, Color> {
        // KeyValuePairs doesn't support dynamic construction,
        // so we use chartForegroundStyleScale with the domain/range overload instead.
        [:]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Daily Cost by Model")
                .font(.system(size: 13, weight: .medium))

            Chart(dailyModelCost) { entry in
                BarMark(
                    x: .value("Date", entry.date),
                    y: .value("Cost", entry.cost)
                )
                .foregroundStyle(by: .value("Model", entry.model))
                .opacity(hoveredDate == nil || hoveredDate == entry.date ? 1.0 : 0.4)
            }
            .chartForegroundStyleScale(domain: modelNames, range: modelNames.map { colorForModel($0) })
            .chartXAxis {
                AxisMarks(values: .automatic) { value in
                    AxisValueLabel {
                        if let str = value.as(String.self) {
                            Text(formatChartDate(str))
                                .font(.system(size: 11))
                        }
                    }
                    AxisGridLine()
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let val = value.as(Double.self) {
                            Text(formatCost(val))
                                .font(.system(size: 11))
                        }
                    }
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
                }
            }
            .chartLegend(position: .bottom, spacing: 16)
            .frame(height: 200)
            .chartOverlay { proxy in
                chartHoverOverlay(proxy: proxy) { date in
                    hoveredDate = date
                }
            }
            .overlay(alignment: .topLeading) {
                if let date = hoveredDate {
                    let entries = dailyModelCost.filter { $0.date == date }
                    if !entries.isEmpty {
                        ChartTooltip(
                            items: entries.map { entry in
                                (entry.model, formatCost(entry.cost), colorForModel(entry.model))
                            },
                            date: formatChartDate(date)
                        )
                        .padding(8)
                    }
                }
            }
            .frame(maxWidth: 800)
            .padding(16)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Model Efficiency Table

private struct ModelEfficiencyTableView: View {
    let rows: [ModelEfficiencyRow]

    private func isHighlightedRow(_ row: ModelEfficiencyRow) -> Bool {
        let lowered = row.model.lowercased()
        let isExpensive = lowered.contains("opus") || lowered.contains("sonnet")
        return row.avgOutputPerTurn < 200 && isExpensive
    }

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Model Efficiency")
                    .font(Typography.sectionTitle)

                // Header row
                HStack(spacing: 0) {
                    Text("Model")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Turns")
                        .frame(width: 70, alignment: .trailing)
                    Text("Avg Output")
                        .frame(width: 90, alignment: .trailing)
                    Text("Cost")
                        .frame(width: 80, alignment: .trailing)
                    Text("$/Turn")
                        .frame(width: 80, alignment: .trailing)
                    Text("% Total")
                        .frame(width: 70, alignment: .trailing)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)

                // Data rows
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Divider().padding(.horizontal, 12)
                    }
                    HStack(spacing: 0) {
                        Text(row.model)
                            .font(Typography.bodyMedium)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(row.turnCount)")
                            .font(Typography.code)
                            .frame(width: 70, alignment: .trailing)
                        Text(formatTokens(row.avgOutputPerTurn))
                            .font(Typography.code)
                            .frame(width: 90, alignment: .trailing)
                        Text(formatCost(row.totalCost))
                            .font(Typography.code)
                            .frame(width: 80, alignment: .trailing)
                        Text(formatCost(row.costPerTurn))
                            .font(Typography.code)
                            .frame(width: 80, alignment: .trailing)
                        Text(String(format: "%.1f%%", row.percentOfTotalCost))
                            .font(Typography.code)
                            .frame(width: 70, alignment: .trailing)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.md)
                            .fill(isHighlightedRow(row)
                                  ? Color.yellow.opacity(0.08)
                                  : Color.clear)
                    )
                }
            }
        }
    }
}

// MARK: - What-If Calculator

private struct WhatIfCalculatorView: View {
    @Binding var threshold: Int
    let savings: WhatIfSavings

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 16) {
                Text("What-If Calculator")
                    .font(Typography.sectionTitle)

                Text("If short Opus turns (under the output threshold) were routed to Sonnet instead:")
                    .font(Typography.body)
                    .foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    Text("Output threshold:")
                        .font(Typography.body)

                    Stepper(
                        value: $threshold,
                        in: 50...1000,
                        step: 50
                    ) {
                        Text("\(threshold) tokens")
                            .font(Typography.code)
                            .frame(width: 100)
                    }
                }

                Divider()

                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Current Cost")
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                        Text(formatCost(savings.currentCost))
                            .font(Typography.displaySmall)
                    }

                    Image(systemName: "arrow.right")
                        .foregroundStyle(.tertiary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hypothetical Cost")
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                        Text(formatCost(savings.hypotheticalCost))
                            .font(Typography.displaySmall)
                            .foregroundStyle(.blue)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Potential Savings")
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Text(formatCost(savings.savings))
                                .font(Typography.displaySmall)
                                .foregroundStyle(.green)
                            if savings.savingsPercent > 0 {
                                Text(String(format: "(%.1f%%)", savings.savingsPercent))
                                    .font(Typography.caption)
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }

                if savings.turnsAffected > 0 {
                    Text("\(savings.turnsAffected) turns would be affected")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

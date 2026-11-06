import SwiftUI
import Charts

/// Who approved or refused tool calls in the window, from the
/// `permissionDecision` Claude Code records on every tool result.
struct PermissionAnalyticsView: View {
    let data: PermissionAnalytics

    var body: some View {
        if data.totalDecisions == 0 {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("No Permission Data")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Permission decisions are recorded by Claude Code 2.1.29x and later.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        StatCard(title: "Tool Calls Decided", value: formatTokens(data.totalDecisions))
                        StatCard(title: "Denial Rate", value: percent(Double(data.totalDenials) / Double(data.totalDecisions)),
                                 subtitle: "\(data.totalDenials) refused")
                        StatCard(title: "Safety Check Trips", value: "\(data.safetyCheckTrips)")
                        StatCard(title: "Sandboxed", value: data.sandboxedShare.map(percent) ?? "n/a")
                    }
                    .padding(.horizontal, 24)

                    HStack(alignment: .top, spacing: 16) {
                        countBars(title: "Approved By", rows: data.approvalsBySource)
                        countBars(title: "Refused By", rows: data.denialsByReason)
                    }
                    .padding(.horizontal, 24)

                    if !data.dailyDenials.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Refusals per Day")
                                .font(.headline)
                            Chart(data.dailyDenials) { day in
                                BarMark(x: .value("Date", day.date), y: .value("Refusals", day.count))
                                    .foregroundStyle(Color.okabeVermillion)
                            }
                            .stridedDateXAxis(dates: data.dailyDenials.map(\.date))
                            .frame(height: 160)
                        }
                        .padding(.horizontal, 24)
                    }

                    if !data.circuitBreakers.isEmpty || !data.denyRuleSources.isEmpty {
                        HStack(alignment: .top, spacing: 16) {
                            countTable(title: "Safety Checks Tripped", rows: data.circuitBreakers)
                            countTable(title: "Deny Rules By Source", rows: data.denyRuleSources)
                        }
                        .padding(.horizontal, 24)
                    }
                }
                .padding(.vertical, 24)
            }
        }
    }

    @ViewBuilder
    private func countBars(title: String, rows: [LabeledCount]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            if rows.isEmpty {
                Text("None in this range")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else {
                Chart(Array(rows.enumerated()), id: \.element.id) { index, row in
                    BarMark(x: .value("Count", row.count), y: .value("Source", row.label))
                        .foregroundStyle(Color.chartCategorical[index % Color.chartCategorical.count])
                        .annotation(position: .trailing) {
                            Text("\(row.count)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                }
                .chartLegend(.hidden)
                .frame(height: CGFloat(max(rows.count, 1)) * 28 + 20)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func countTable(title: String, rows: [LabeledCount]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            if rows.isEmpty {
                Text("None in this range")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            ForEach(rows) { row in
                HStack {
                    Text(row.label)
                        .font(.system(size: 12, design: .monospaced))
                    Spacer()
                    Text("\(row.count)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func percent(_ value: Double) -> String {
        let pct = value * 100
        return pct > 0 && pct < 1 ? "<1%" : "\(Int(pct.rounded()))%"
    }
}

import SwiftUI
import Charts

// MARK: - Shared

/// Best-to-worst outcome colors on the ordered scale ramp (see AppColors).
private func outcomeColor(_ outcome: FacetOutcome) -> Color {
    switch outcome {
    case .fullyAchieved: return Color.scaleLow
    case .mostlyAchieved: return Color.scaleMedium
    case .partiallyAchieved: return Color.scaleHigh
    case .notAchieved: return Color.scaleMax
    case .unclear: return Color.okabeGray
    }
}

private struct CoverageBanner: View {
    let coverage: InsightsCoverage

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
            Text(bannerText)
                .font(.system(size: 11))
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AnyShapeStyle(.quaternary))
    }

    private var bannerText: String {
        if coverage.facetCount == 0 {
            return "No session insights found. Run /insights in Claude Code to generate them."
        }
        var text = "Facets cover \(coverage.facetCount) of \(coverage.storeSessionCount) sessions"
        if let latest = coverage.latestFacetDate {
            text += ", latest \(latest.formatted(date: .abbreviated, time: .omitted))"
        }
        text += ". Run /insights in Claude Code to refresh."
        return text
    }
}

// MARK: - Sidebar

struct InsightsSidebarContent: View {
    let filterText: String
    let data: InsightsData
    @Binding var selectedSessionId: String?
    @State private var outcomeFilter: FacetOutcome?

    private var filtered: [SessionInsight] {
        data.insights.filter { insight in
            if let outcomeFilter, insight.facet.outcome != outcomeFilter { return false }
            if filterText.isEmpty { return true }
            return (insight.facet.underlyingGoal ?? "").localizedCaseInsensitiveContains(filterText)
                || (insight.facet.briefSummary ?? "").localizedCaseInsensitiveContains(filterText)
                || (insight.summary?.title ?? "").localizedCaseInsensitiveContains(filterText)
        }
    }

    private var fullyAchievedShare: Int {
        guard !data.insights.isEmpty else { return 0 }
        let achieved = data.insights.filter { $0.facet.outcome == .fullyAchieved }.count
        return Int((Double(achieved) / Double(data.insights.count) * 100).rounded())
    }

    private var totalFriction: Int {
        data.frictionTotals.reduce(0) { $0 + $1.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CoverageBanner(coverage: data.coverage)

            if data.insights.isEmpty {
                SidebarEmptyStateView(icon: "lightbulb", text: "No insights yet")
            } else {
                HStack(spacing: 12) {
                    summaryStat(value: "\(data.coverage.facetCount)", label: "sessions")
                    summaryStat(value: "\(fullyAchievedShare)%", label: "fully achieved")
                    summaryStat(value: "\(totalFriction)", label: "friction events")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                Picker("Outcome", selection: $outcomeFilter) {
                    Text("All outcomes").tag(FacetOutcome?.none)
                    ForEach(data.outcomeDistribution, id: \.outcome) { entry in
                        Text(entry.outcome.label).tag(FacetOutcome?.some(entry.outcome))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)

                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { insight in
                        InsightRow(insight: insight, isSelected: selectedSessionId == insight.id) {
                            selectedSessionId = insight.id
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func summaryStat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

private struct InsightRow: View {
    let insight: SessionInsight
    let isSelected: Bool
    let onSelect: () -> Void

    private var title: String {
        insight.summary?.title ?? insight.facet.underlyingGoal ?? String(insight.id.prefix(8))
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Circle()
                    .fill(outcomeColor(insight.facet.outcome))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Typography.body)
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? .white : .primary)
                    HStack(spacing: 6) {
                        Text(insight.facet.outcome.label)
                        if insight.facet.frictionTotal > 0 {
                            Text("\(insight.facet.frictionTotal) friction")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Main Panel

struct InsightsMainPanelView: View {
    @Environment(SessionStore.self) private var store
    let selectedSessionId: String?
    var onNavigateToSession: ((String, String, String?) -> Void)?

    var body: some View {
        let data = store.insightsData
        if data.insights.isEmpty {
            EmptyStateView(
                icon: "lightbulb",
                title: "No session insights",
                message: "Run /insights in Claude Code to classify your sessions (outcome, friction, satisfaction). The results are read from ~/.claude/usage-data."
            )
        } else if let id = selectedSessionId,
                  let insight = data.insights.first(where: { $0.id == id }) {
            InsightDetailView(insight: insight, onNavigateToSession: onNavigateToSession)
        } else {
            InsightsAggregateView(data: data)
        }
    }
}

private struct InsightsAggregateView: View {
    let data: InsightsData

    /// (outcome, avg cost) for insights joined to a parsed session.
    private var costByOutcome: [(outcome: FacetOutcome, avgCost: Double)] {
        var sums: [FacetOutcome: (total: Double, count: Int)] = [:]
        for insight in data.insights {
            guard let cost = insight.summary?.estimatedCost else { continue }
            let entry = sums[insight.facet.outcome] ?? (0, 0)
            sums[insight.facet.outcome] = (entry.total + cost, entry.count + 1)
        }
        return sums
            .map { (outcome: $0.key, avgCost: $0.value.total / Double($0.value.count)) }
            .sorted { $0.outcome.rank < $1.outcome.rank }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CardView {
                    VStack(alignment: .leading, spacing: 10) {
                        ConfigSectionHeader(title: "OUTCOME DISTRIBUTION")
                        Chart(data.outcomeDistribution, id: \.outcome) { entry in
                            BarMark(
                                x: .value("Sessions", entry.count),
                                y: .value("Outcome", entry.outcome.label)
                            )
                            .foregroundStyle(outcomeColor(entry.outcome))
                        }
                        .chartLegend(.hidden)
                        .frame(height: CGFloat(data.outcomeDistribution.count) * 34 + 20)
                    }
                }

                if !data.frictionTotals.isEmpty {
                    CardView {
                        VStack(alignment: .leading, spacing: 10) {
                            ConfigSectionHeader(title: "FRICTION FREQUENCY")
                            Chart(data.frictionTotals, id: \.kind) { entry in
                                BarMark(
                                    x: .value("Count", entry.count),
                                    y: .value("Kind", entry.kind.replacingOccurrences(of: "_", with: " "))
                                )
                                .foregroundStyle(Color.okabeOrange)
                            }
                            .chartLegend(.hidden)
                            .frame(height: CGFloat(data.frictionTotals.count) * 34 + 20)
                        }
                    }
                }

                if !costByOutcome.isEmpty {
                    CardView {
                        VStack(alignment: .leading, spacing: 10) {
                            ConfigSectionHeader(title: "AVERAGE COST BY OUTCOME")
                            Chart(costByOutcome, id: \.outcome) { entry in
                                BarMark(
                                    x: .value("Avg cost", entry.avgCost),
                                    y: .value("Outcome", entry.outcome.label)
                                )
                                .foregroundStyle(outcomeColor(entry.outcome))
                            }
                            .chartLegend(.hidden)
                            .chartXAxis {
                                AxisMarks { value in
                                    AxisGridLine()
                                    AxisValueLabel {
                                        if let cost = value.as(Double.self) {
                                            Text(formatCost(cost))
                                        }
                                    }
                                }
                            }
                            .frame(height: CGFloat(costByOutcome.count) * 34 + 20)
                            Text("Only sessions whose transcript is still in the local corpus carry a cost.")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct InsightDetailView: View {
    let insight: SessionInsight
    var onNavigateToSession: ((String, String, String?) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(outcomeColor(insight.facet.outcome))
                    .frame(width: 10, height: 10)
                Text(insight.summary?.title ?? String(insight.id.prefix(8)))
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Text(insight.facet.outcome.label)
                    .font(Typography.micro)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(AnyShapeStyle(.quaternary))
                    .clipShape(Capsule())
                    .foregroundStyle(.secondary)
                Spacer()
                if let summary = insight.summary {
                    Button("Open session") {
                        onNavigateToSession?(summary.projectId, summary.id, nil)
                    }
                    .font(.system(size: 11))
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    CardView {
                        VStack(alignment: .leading, spacing: 8) {
                            ConfigSectionHeader(title: "GOAL")
                            if let goal = insight.facet.underlyingGoal {
                                Text(goal).font(.system(size: 12)).textSelection(.enabled)
                            }
                            if let summaryText = insight.facet.briefSummary, !summaryText.isEmpty {
                                Divider()
                                Text(summaryText)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }

                    CardView {
                        VStack(alignment: .leading, spacing: 8) {
                            ConfigSectionHeader(title: "CLASSIFICATION")
                            factRow("Session type", insight.facet.sessionType?.replacingOccurrences(of: "_", with: " "))
                            factRow("Helpfulness", insight.facet.claudeHelpfulness?.replacingOccurrences(of: "_", with: " "))
                            factRow("Primary success", insight.facet.primarySuccess?.replacingOccurrences(of: "_", with: " "))
                            if let satisfaction = insight.facet.userSatisfactionCounts, !satisfaction.isEmpty {
                                factRow("Satisfaction", satisfaction
                                    .sorted { $0.key < $1.key }
                                    .map { "\($0.key.replacingOccurrences(of: "_", with: " ")): \($0.value)" }
                                    .joined(separator: ", "))
                            }
                        }
                    }

                    if insight.facet.frictionTotal > 0 {
                        CardView {
                            VStack(alignment: .leading, spacing: 8) {
                                ConfigSectionHeader(title: "FRICTION")
                                ForEach((insight.facet.frictionCounts ?? [:]).sorted { $0.key < $1.key }, id: \.key) { kind, count in
                                    factRow(kind.replacingOccurrences(of: "_", with: " "), "\(count)")
                                }
                                if let detail = insight.facet.frictionDetail, !detail.isEmpty {
                                    Divider()
                                    Text(detail)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }

                    if insight.meta != nil || insight.summary != nil {
                        CardView {
                            VStack(alignment: .leading, spacing: 8) {
                                ConfigSectionHeader(title: "SESSION STATS")
                                if let cost = insight.summary?.estimatedCost {
                                    factRow("Estimated cost", formatCost(cost))
                                }
                                if let meta = insight.meta {
                                    factRow("Duration", meta.durationMinutes.map { "\(Int($0.rounded())) min" })
                                    factRow("Interruptions", meta.userInterruptions.map(String.init))
                                    factRow("Tool errors", meta.toolErrors.map(String.init))
                                    if let added = meta.linesAdded, let removed = meta.linesRemoved {
                                        factRow("Lines changed", "+\(added) / -\(removed)")
                                    }
                                    factRow("Files modified", meta.filesModified.map(String.init))
                                    factRow("Project", meta.projectPath)
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func factRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 130, alignment: .leading)
                Text(value)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
            }
        }
    }
}

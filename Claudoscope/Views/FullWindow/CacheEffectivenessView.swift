import SwiftUI
import Charts

struct CacheEffectivenessView: View {
    let data: CacheAnalytics
    let dailyUsage: [DailyUsage]

    private var isEmpty: Bool {
        data.totalCacheReadTokens == 0 && data.totalCacheWriteTokens == 0
    }

    private var hitRateColor: Color {
        if data.hitRatio > 0.8 { return .green }
        if data.hitRatio > 0.5 { return .orange }
        return .red
    }

    private var totalCacheTokens: Int {
        data.totalCacheReadTokens + data.totalCacheWriteTokens
    }

    private var reuseRatioText: String {
        String(format: "%.1fx", data.averageReuseRate)
    }

    var body: some View {
        if isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "archivebox")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("No cache data available")
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
                Text("Cache analytics will appear once sessions with cached tokens are recorded.")
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Section 1: Stat cards
                    HStack(spacing: 12) {
                        StatCard(
                            title: "Hit Rate",
                            value: String(format: "%.0f%%", data.hitRatio * 100)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.lg)
                                .strokeBorder(hitRateColor.opacity(0.3), lineWidth: 1)
                        )

                        StatCard(
                            title: "Savings",
                            value: formatCost(data.costSavings)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.lg)
                                .strokeBorder(Color.green.opacity(0.3), lineWidth: 1)
                        )

                        StatCard(
                            title: "Cache Tokens",
                            value: formatTokens(totalCacheTokens)
                        )

                        StatCard(
                            title: "Avg Reuse",
                            value: reuseRatioText
                        )
                    }
                    .padding(.horizontal, 24)

                    // Section 2: Cache hit ratio over time (with busting annotations + stability callout)
                    if !data.dailyHitRatio.isEmpty {
                        CacheHitRatioChartView(
                            dailyHitRatio: data.dailyHitRatio,
                            cacheBustingDays: data.cacheBustingDays,
                            reuseRate: data.averageReuseRate
                        )
                        .padding(.horizontal, 24)
                    }

                    // Section 3: 5m vs 1h tier breakdown
                    if data.totalCache5mTokens > 0 || data.totalCache1hTokens > 0 {
                        CacheTierBreakdownView(
                            tokens5m: data.totalCache5mTokens,
                            tokens1h: data.totalCache1hTokens,
                            tierCost: data.tierCostBreakdown,
                            totalCacheWrite: data.totalCacheWriteTokens
                        )
                        .padding(.horizontal, 24)
                    }

                    // Section 4: Per-session cache efficiency table
                    if !data.sessionEfficiency.isEmpty {
                        SessionCacheEfficiencyView(sessions: data.sessionEfficiency)
                            .padding(.horizontal, 24)
                    }

                    // Section 5: Model-aware cache savings
                    if !data.modelSavings.isEmpty {
                        ModelCacheSavingsView(savings: data.modelSavings)
                            .padding(.horizontal, 24)
                    }

                    // Section 6: Cost breakdown
                    CacheCostBreakdownView(data: data)
                        .padding(.horizontal, 24)
                }
                .padding(.vertical, 24)
            }
        }
    }
}

// MARK: - Cache Hit Ratio Chart

private struct CacheHitRatioChartView: View {
    let dailyHitRatio: [(date: String, ratio: Double)]
    let cacheBustingDays: [String]
    let reuseRate: Double
    @State private var hoveredDate: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cache Hit Ratio Over Time")
                .font(.system(size: 13, weight: .medium))

            Chart {
                ForEach(dailyHitRatio, id: \.date) { entry in
                    LineMark(
                        x: .value("Date", entry.date),
                        y: .value("Ratio", entry.ratio)
                    )
                    .foregroundStyle(Color.green)
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("Date", entry.date),
                        y: .value("Ratio", entry.ratio)
                    )
                    .foregroundStyle(Color.green.opacity(0.15))
                    .interpolationMethod(.catmullRom)
                }

                // Cache busting annotations
                ForEach(cacheBustingDays, id: \.self) { day in
                    RuleMark(x: .value("Date", day))
                        .foregroundStyle(.red.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .annotation(position: .top, alignment: .center) {
                            Text("drop")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
                        }
                }
            }
            .chartYScale(domain: 0...1)
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
                AxisMarks(values: [0, 0.25, 0.5, 0.75, 1.0]) { value in
                    AxisValueLabel {
                        if let val = value.as(Double.self) {
                            Text(String(format: "%.0f%%", val * 100))
                                .font(.system(size: 11))
                        }
                    }
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
                }
            }
            .frame(height: 200)
            .chartOverlay { proxy in
                chartHoverOverlay(proxy: proxy) { date in
                    hoveredDate = date
                }
            }
            .overlay(alignment: .topLeading) {
                if let date = hoveredDate,
                   let entry = dailyHitRatio.first(where: { $0.date == date }) {
                    ChartTooltip(items: [
                        ("Hit Rate", String(format: "%.1f%%", entry.ratio * 100), .green),
                    ], date: formatChartDate(date))
                    .padding(8)
                }
            }
            .frame(maxWidth: 800)
            .padding(16)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
            .frame(maxWidth: .infinity)

            // Stability callout
            if reuseRate < 5.0 {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 12))
                    Text("Low reuse rate (\(String(format: "%.1fx", reuseRate))) suggests your system prompt or tools are changing frequently between turns. A stable prefix leads to higher cache hit rates.")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.md))
            }
        }
    }
}

// MARK: - TTL Tier Breakdown

private struct CacheTierBreakdownView: View {
    let tokens5m: Int
    let tokens1h: Int
    let tierCost: CacheTierCost
    let totalCacheWrite: Int

    private var tier1hFraction: Double {
        let total = tokens5m + tokens1h
        guard total > 0 else { return 0 }
        return Double(tokens1h) / Double(total)
    }

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Cache Write TTL Tiers")
                    .font(Typography.sectionTitle)

                HStack(spacing: 24) {
                    // Stacked bar
                    VStack(alignment: .leading, spacing: 4) {
                        GeometryReader { geo in
                            let total = tokens5m + tokens1h
                            let frac5m = total > 0 ? CGFloat(tokens5m) / CGFloat(total) : 0.5
                            HStack(spacing: 1) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(.blue.opacity(0.6))
                                    .frame(width: max(geo.size.width * frac5m, 2))
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(.purple.opacity(0.6))
                                    .frame(width: max(geo.size.width * (1 - frac5m), 2))
                            }
                        }
                        .frame(height: 24)
                        .frame(maxWidth: 300)

                        HStack(spacing: 16) {
                            Label("5-min", systemImage: "circle.fill")
                                .font(Typography.caption)
                                .foregroundStyle(.blue.opacity(0.8))
                            Label("1-hour", systemImage: "circle.fill")
                                .font(Typography.caption)
                                .foregroundStyle(.purple.opacity(0.8))
                        }
                    }

                    // Cost text
                    VStack(alignment: .leading, spacing: 4) {
                        Text("5-min tier: \(formatTokens(tokens5m)), \(formatCost(tierCost.cost5m))")
                            .font(Typography.body)
                            .foregroundStyle(.secondary)
                        Text("1-hour tier: \(formatTokens(tokens1h)), \(formatCost(tierCost.cost1h))")
                            .font(Typography.body)
                            .foregroundStyle(.secondary)
                    }
                }

                // Contextual note about expensive 1h tier
                if tier1hFraction > 0.5 {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.blue)
                            .font(.system(size: 12))
                        Text("Over half your cache writes use the 1-hour tier (\(formatCost(tierCost.cost1h)) vs \(formatCost(tierCost.cost5m)) for 5-min). Short coding sessions may not benefit from the longer TTL.")
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.md))
                }
            }
        }
    }
}

// MARK: - Session Cache Efficiency Table

private struct SessionCacheEfficiencyView: View {
    let sessions: [SessionCacheEfficiency]

    private var topSavings: Double {
        sessions.prefix(3).reduce(0) { $0 + $1.savingsAmount }
    }

    private var lowHitSessions: [SessionCacheEfficiency] {
        sessions.filter { $0.hitRatio < 0.5 }
    }

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Session Cache Efficiency")
                    .font(Typography.sectionTitle)

                // Table header
                HStack(spacing: 0) {
                    Text("Session")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Hit Rate")
                        .frame(width: 70, alignment: .trailing)
                    Text("Cache Reads")
                        .frame(width: 100, alignment: .trailing)
                    Text("Savings")
                        .frame(width: 80, alignment: .trailing)
                    Text("Model")
                        .frame(width: 70, alignment: .trailing)
                }
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

                Divider()

                // Table rows (show top 15)
                ForEach(Array(sessions.prefix(15).enumerated()), id: \.element.id) { index, session in
                    if index > 0 {
                        Divider()
                    }
                    HStack(spacing: 0) {
                        Text(session.sessionTitle)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(String(format: "%.0f%%", session.hitRatio * 100))
                            .frame(width: 70, alignment: .trailing)
                        Text(formatTokens(session.cacheReadTokens))
                            .frame(width: 100, alignment: .trailing)
                        Text(formatCost(session.savingsAmount))
                            .frame(width: 80, alignment: .trailing)
                        Text(session.primaryModel ?? "-")
                            .frame(width: 70, alignment: .trailing)
                    }
                    .font(Typography.body)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 4)
                    .background(rowBackground(index: index, total: sessions.count), in: RoundedRectangle(cornerRadius: 4))
                }

                // Insight line
                if sessions.count >= 3 {
                    let lowHitCost = lowHitSessions.reduce(0.0) { $0 + $1.savingsAmount }
                    Text("Your top 3 sessions saved \(formatCost(topSavings))." + (lowHitSessions.isEmpty ? "" : " Sessions with <50% hit rate could save \(formatCost(lowHitCost)) more with better caching."))
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
        }
    }

    private func rowBackground(index: Int, total: Int) -> Color {
        if index < 3 {
            return .green.opacity(0.06)
        }
        if total > 3 && index >= total - 3 && index >= 3 {
            return .orange.opacity(0.05)
        }
        return .clear
    }
}

// MARK: - Model Cache Savings

private struct ModelCacheSavingsView: View {
    let savings: [ModelCacheSavings]

    private func modelColor(_ model: String) -> Color {
        switch model.lowercased() {
        case "opus", "opus4": return .purple
        case "sonnet": return .blue
        case "haiku", "haiku3": return .green
        default: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Savings by Model")
                .font(.system(size: 13, weight: .medium))

            VStack(alignment: .leading, spacing: 12) {
                Chart {
                    ForEach(savings) { entry in
                        BarMark(
                            x: .value("Savings", entry.totalSavings),
                            y: .value("Model", entry.model)
                        )
                        .foregroundStyle(modelColor(entry.model).opacity(0.7))
                        .cornerRadius(4)
                        .annotation(position: .trailing) {
                            Text(formatCost(entry.totalSavings))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .chartXAxis {
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
                .frame(height: CGFloat(savings.count) * 40 + 20)

                // Savings rate annotations
                HStack(spacing: 16) {
                    ForEach(savings) { entry in
                        Text("\(entry.model.capitalized): $\(String(format: "%.2f", entry.savingsPerMTok))/MTok saved")
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: 600)
            .padding(16)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Cost Breakdown

private struct CacheCostBreakdownView: View {
    let data: CacheAnalytics

    private var costEntries: [(label: String, cost: Double, color: Color)] {
        [
            ("Actual Cost", data.actualCost, .green.opacity(0.6)),
            ("Without Cache", data.hypotheticalUncachedCost, .orange.opacity(0.6)),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cost Breakdown")
                .font(.system(size: 13, weight: .medium))

            VStack(alignment: .leading, spacing: 12) {
                Chart {
                    ForEach(costEntries, id: \.label) { entry in
                        BarMark(
                            x: .value("Category", entry.label),
                            y: .value("Cost", entry.cost)
                        )
                        .foregroundStyle(entry.color)
                        .cornerRadius(4)
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
                .frame(height: 180)

                HStack(spacing: 16) {
                    Text("Actual: \(formatCost(data.actualCost))")
                        .font(Typography.body)
                        .foregroundStyle(.secondary)
                    Text("|")
                        .foregroundStyle(.quaternary)
                    Text("Without cache: \(formatCost(data.hypotheticalUncachedCost))")
                        .font(Typography.body)
                        .foregroundStyle(.secondary)
                    Text("|")
                        .foregroundStyle(.quaternary)
                    Text("You saved: \(formatCost(data.costSavings))")
                        .font(Typography.bodyMedium)
                        .foregroundStyle(.green)
                }
            }
            .frame(maxWidth: 400)
            .padding(16)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
            .frame(maxWidth: .infinity)
        }
    }
}

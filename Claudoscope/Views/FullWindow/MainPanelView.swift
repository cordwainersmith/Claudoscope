import SwiftUI
import Charts

struct MainPanelView: View {
    let rail: RailItem
    @Environment(SessionStore.self) private var store

    // Plans
    @Binding var selectedPlanFilename: String?

    // Config
    let selectedHookEventId: String?
    @Binding var selectedCommandName: String?
    @Binding var selectedSkillName: String?
    let selectedMcpName: String?
    @Binding var selectedMemoryId: String?

    // Config Health
    @Binding var selectedLintResultId: String?
    @Binding var hiddenLintSeverities: Set<LintSeverity>
    let selectedProjectId: String?

    // Settings
    @Binding var selectedSettingsSection: String?

    // Session navigation from config health
    var onNavigateToSession: ((String, String) -> Void)?

    var body: some View {
        Group {
            switch rail {
            case .analytics:
                AnalyticsDetailView()
            case .sessions:
                if let session = store.selectedSession {
                    ChatView(session: session)
                } else {
                    EmptyStateView(
                        icon: "text.line.first.and.arrowtriangle.forward",
                        title: "Select a session",
                        message: "Choose a session from the sidebar to view its conversation."
                    )
                }
            case .plans:
                PlansMainPanelView(
                    selectedPlanFilename: $selectedPlanFilename,
                    planDetail: store.selectedPlanDetail,
                    isLoading: store.plansLoading
                )
            case .timeline:
                TimelineMainPanelView(
                    entries: store.timelineEntries,
                    isLoading: store.timelineLoading
                )
            case .hooks:
                HooksMainPanelView(
                    hookGroups: store.hookGroups,
                    selectedEventId: selectedHookEventId
                )
            case .commands:
                CommandsMainPanelView(
                    commands: store.commands,
                    selectedCommandName: $selectedCommandName
                )
            case .skills:
                SkillsMainPanelView(
                    skills: store.skills,
                    selectedSkillName: $selectedSkillName
                )
            case .mcps:
                McpsMainPanelView(
                    mcpServers: store.mcpServers,
                    selectedMcpName: selectedMcpName
                )
            case .memory:
                MemoryMainPanelView(
                    memoryFiles: store.memoryFiles,
                    selectedMemoryId: $selectedMemoryId
                )
            case .configHealth:
                ConfigHealthMainPanelView(
                    lintResults: store.lintResults,
                    lintSummary: store.lintSummary,
                    isLoading: store.lintLoading,
                    isSecretScanLoading: store.secretScanLoading,
                    selectedResultId: $selectedLintResultId,
                    hiddenSeverities: $hiddenLintSeverities,
                    onRescan: {
                        Task {
                            await store.runConfigLint(projectId: selectedProjectId)
                        }
                    },
                    onNavigateToSession: onNavigateToSession
                )
            case .settings:
                SettingsMainPanelView(selectedSection: $selectedSettingsSection)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Analytics Detail

struct AnalyticsDetailView: View {
    @Environment(SessionStore.self) private var store

    var data: AnalyticsData { store.analyticsData }

    var selectedProjectName: String? {
        guard let id = store.selectedAnalyticsProjectId else { return nil }
        return store.projects.first(where: { $0.id == id })?.name
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header with title, filter badge, and time range
                AnalyticsHeaderView(
                    selectedProjectName: selectedProjectName,
                    onClearProject: {
                        store.selectedAnalyticsProjectId = nil
                        store.recomputeAnalytics()
                    }
                )
                .padding(.horizontal, 24)

                // Stat cards
                HStack(spacing: 12) {
                    StatCard(title: "Sessions", value: "\(data.totalSessions)")
                    StatCard(title: "Messages", value: formatTokens(data.totalMessages))
                    StatCard(
                        title: "Tokens",
                        value: formatTokens(data.totalTokens),
                        subtitle: data.totalCacheTokens > 0 ? "+ \(formatTokens(data.totalCacheTokens)) cache" : nil
                    )
                    StatCard(title: "Est. Cost", value: formatCost(data.totalCost), isHighlighted: true)
                }
                .padding(.horizontal, 24)

                // Daily usage chart
                if !data.dailyUsage.isEmpty {
                    DailyUsageChartView(dailyUsage: data.dailyUsage)
                        .padding(.horizontal, 24)
                }

                // Bottom row: Cost by Project + Model Distribution
                HStack(alignment: .top, spacing: 16) {
                    CostByProjectView(projectCosts: data.projectCosts, totalCost: data.totalCost)
                    ModelDistributionView(modelUsage: data.modelUsage)
                }
                .padding(.horizontal, 24)
            }
            .padding(.vertical, 24)
        }
    }
}

// MARK: - Analytics Header

private struct AnalyticsHeaderView: View {
    @Environment(SessionStore.self) private var store
    let selectedProjectName: String?
    let onClearProject: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("Analytics")
                .font(.system(size: 18, weight: .medium))

            if let name = selectedProjectName {
                HStack(spacing: 4) {
                    Text(name)
                        .font(.system(size: 12, weight: .medium))
                    Button(action: onClearProject) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(Capsule())
            }

            Spacer()

            // Time range picker
            TimeRangePicker()
        }
    }
}

private struct TimeRangePicker: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 0) {
            ForEach(AnalyticsTimeRange.allCases, id: \.self) { range in
                Button {
                    store.analyticsTimeRange = range
                    store.recomputeAnalytics()
                } label: {
                    Text(range.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(store.analyticsTimeRange == range ? Color.accentColor.opacity(0.15) : .clear)
                        .foregroundStyle(store.analyticsTimeRange == range ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)

                if range != AnalyticsTimeRange.allCases.last {
                    Divider().frame(height: 16)
                }
            }
        }
        .background(.bar)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 1))

        if store.analyticsTimeRange == .custom {
            HStack(spacing: 4) {
                DatePicker("", selection: $store.analyticsCustomFrom, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.field)
                Text("to")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                DatePicker("", selection: $store.analyticsCustomTo, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.field)
            }
            .onChange(of: store.analyticsCustomFrom) { _, _ in store.recomputeAnalytics() }
            .onChange(of: store.analyticsCustomTo) { _, _ in store.recomputeAnalytics() }
        }
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let value: String
    var subtitle: String? = nil
    var isHighlighted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: 22, weight: .medium, design: .monospaced))
                    .foregroundStyle(isHighlighted ? Color.orange : .primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }
}

// MARK: - Daily Usage Chart

struct DailyUsageChartView: View {
    let dailyUsage: [DailyUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            IOTokensChartView(dailyUsage: dailyUsage)
            CacheTokensChartView(dailyUsage: dailyUsage)
        }
    }
}

private struct IOTokensChartView: View {
    let dailyUsage: [DailyUsage]
    @State private var hoveredDate: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Input & Output Tokens")
                .font(.system(size: 13, weight: .medium))

            Chart(dailyUsage) { day in
                BarMark(
                    x: .value("Date", day.date),
                    y: .value("Tokens", day.inputTokens)
                )
                .foregroundStyle(by: .value("Type", "Input"))
                .opacity(hoveredDate == nil || hoveredDate == day.date ? 1.0 : 0.4)

                BarMark(
                    x: .value("Date", day.date),
                    y: .value("Tokens", day.outputTokens)
                )
                .foregroundStyle(by: .value("Type", "Output"))
                .opacity(hoveredDate == nil || hoveredDate == day.date ? 1.0 : 0.4)
            }
            .chartForegroundStyleScale([
                "Input": Color.blue.opacity(0.7),
                "Output": Color.green.opacity(0.7),
            ])
            .dailyChartAxes()
            .chartLegend(position: .bottom, spacing: 16)
            .frame(height: 180)
            .chartOverlay { proxy in
                chartHoverOverlay(proxy: proxy) { date in
                    hoveredDate = date
                }
            }
            .overlay(alignment: .topLeading) {
                if let date = hoveredDate,
                   let day = dailyUsage.first(where: { $0.date == date }) {
                    ChartTooltip(items: [
                        ("Input", formatTokens(day.inputTokens), .blue),
                        ("Output", formatTokens(day.outputTokens), .green),
                    ], date: formatChartDate(date))
                    .padding(8)
                }
            }
            .padding(16)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
        }
    }
}

private struct CacheTokensChartView: View {
    let dailyUsage: [DailyUsage]
    @State private var hoveredDate: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cache Tokens")
                .font(.system(size: 13, weight: .medium))

            Chart(dailyUsage) { day in
                BarMark(
                    x: .value("Date", day.date),
                    y: .value("Tokens", day.cacheReadTokens)
                )
                .foregroundStyle(by: .value("Type", "Cache Read"))
                .opacity(hoveredDate == nil || hoveredDate == day.date ? 1.0 : 0.4)

                BarMark(
                    x: .value("Date", day.date),
                    y: .value("Tokens", day.cacheCreationTokens)
                )
                .foregroundStyle(by: .value("Type", "Cache Write"))
                .opacity(hoveredDate == nil || hoveredDate == day.date ? 1.0 : 0.4)
            }
            .chartForegroundStyleScale([
                "Cache Read": Color.purple.opacity(0.5),
                "Cache Write": Color.orange.opacity(0.6),
            ])
            .dailyChartAxes()
            .chartLegend(position: .bottom, spacing: 16)
            .frame(height: 180)
            .chartOverlay { proxy in
                chartHoverOverlay(proxy: proxy) { date in
                    hoveredDate = date
                }
            }
            .overlay(alignment: .topLeading) {
                if let date = hoveredDate,
                   let day = dailyUsage.first(where: { $0.date == date }) {
                    ChartTooltip(items: [
                        ("Cache Read", formatTokens(day.cacheReadTokens), .purple),
                        ("Cache Write", formatTokens(day.cacheCreationTokens), .orange),
                    ], date: formatChartDate(date))
                    .padding(8)
                }
            }
            .padding(16)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
        }
    }
}

private func chartHoverOverlay(proxy: ChartProxy, onDateChange: @escaping (String?) -> Void) -> some View {
    GeometryReader { geo in
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    if let plotFrame = proxy.plotFrame {
                        let origin = geo[plotFrame].origin
                        let adjustedX = location.x - origin.x
                        if let date: String = proxy.value(atX: adjustedX) {
                            onDateChange(date)
                        }
                    }
                case .ended:
                    onDateChange(nil)
                }
            }
    }
}

private struct ChartTooltip: View {
    let items: [(label: String, value: String, color: Color)]
    let date: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(date)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            ForEach(items, id: \.label) { item in
                HStack(spacing: 6) {
                    Circle()
                        .fill(item.color.opacity(0.7))
                        .frame(width: 6, height: 6)
                    Text(item.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(item.value)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
            }
        }
        .padding(8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 1))
    }
}

private extension View {
    func dailyChartAxes() -> some View {
        self
            .chartXAxis {
                AxisMarks(values: .automatic) { value in
                    AxisValueLabel {
                        if let str = value.as(String.self) {
                            Text(formatChartDate(str))
                                .font(.system(size: 10))
                        }
                    }
                    AxisGridLine()
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let intVal = value.as(Int.self) {
                            Text(formatTokens(intVal))
                                .font(.system(size: 10))
                        }
                    }
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
                }
            }
    }
}

private func formatChartDate(_ dateStr: String) -> String {
    // "2026-03-14" -> "3/14" or day-of-week abbreviation
    let parts = dateStr.split(separator: "-")
    guard parts.count == 3,
          let month = Int(parts[1]),
          let day = Int(parts[2]) else { return dateStr }
    return "\(month)/\(day)"
}

// MARK: - Cost by Project

private struct CostByProjectView: View {
    let projectCosts: [ProjectCost]
    let totalCost: Double

    private let barColors: [Color] = [
        .blue, .green, .orange, .red, .purple, .cyan, .yellow, .pink, .mint, .teal
    ]

    var topProjects: [ProjectCost] {
        Array(projectCosts.prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cost by Project")
                .font(.system(size: 13, weight: .medium))

            VStack(spacing: 8) {
                ForEach(Array(topProjects.enumerated()), id: \.element.id) { index, project in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(project.projectName)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                            Text(formatCost(project.totalCost))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            if totalCost > 0 {
                                Text("\(Int((project.totalCost / totalCost) * 100))%")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 30, alignment: .trailing)
                            }
                        }

                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(barColors[index % barColors.count].opacity(0.6))
                                .frame(width: max(4, geo.size.width * (totalCost > 0 ? project.totalCost / totalCost : 0)))
                        }
                        .frame(height: 4)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
    }
}

// MARK: - Model Distribution

private struct ModelDistributionView: View {
    let modelUsage: [ModelUsage]

    private let pieColors: [Color] = [
        .purple, .blue, .green, .orange, .red, .cyan, .yellow, .pink
    ]

    var totalTurns: Int {
        modelUsage.reduce(0) { $0 + $1.turnCount }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model Distribution")
                .font(.system(size: 13, weight: .medium))

            if modelUsage.isEmpty {
                Text("No data")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                HStack(spacing: 24) {
                    // Donut chart
                    ZStack {
                        ForEach(Array(donutSlices().enumerated()), id: \.offset) { index, slice in
                            DonutSlice(
                                startAngle: slice.start,
                                endAngle: slice.end,
                                color: pieColors[index % pieColors.count]
                            )
                        }
                        Circle()
                            .fill(.background)
                            .frame(width: 60, height: 60)
                    }
                    .frame(width: 100, height: 100)

                    // Legend
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(modelUsage.enumerated()), id: \.element.id) { index, usage in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(pieColors[index % pieColors.count])
                                    .frame(width: 8, height: 8)
                                Text(usage.model)
                                    .font(.system(size: 12))
                                Spacer()
                                if totalTurns > 0 {
                                    Text(String(format: "%.1f%%", Double(usage.turnCount) / Double(totalTurns) * 100))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
    }

    private func donutSlices() -> [(start: Angle, end: Angle)] {
        guard totalTurns > 0 else { return [] }
        var slices: [(start: Angle, end: Angle)] = []
        var currentAngle = Angle.degrees(-90)
        for usage in modelUsage {
            let fraction = Double(usage.turnCount) / Double(totalTurns)
            let sweep = Angle.degrees(fraction * 360)
            slices.append((start: currentAngle, end: currentAngle + sweep))
            currentAngle = currentAngle + sweep
        }
        return slices
    }
}

private struct DonutSlice: View {
    let startAngle: Angle
    let endAngle: Angle
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = min(geo.size.width, geo.size.height) / 2
            Path { path in
                path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
                path.addArc(center: center, radius: radius * 0.6, startAngle: endAngle, endAngle: startAngle, clockwise: true)
                path.closeSubpath()
            }
            .fill(color)
        }
    }
}

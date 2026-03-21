import SwiftUI
import Charts

struct AnalyticsDetailView: View {
    @Environment(SessionStore.self) private var store
    @State private var selectedTab: AnalyticsTab = .overview

    enum AnalyticsTab: String, CaseIterable {
        case overview = "Overview"
        case cache = "Cache"
        case models = "Models"
    }

    var data: AnalyticsData { store.analyticsData }

    var selectedProjectName: String? {
        guard let id = store.selectedAnalyticsProjectId else { return nil }
        return store.projects.first(where: { $0.id == id })?.name
    }

    var body: some View {
        VStack(spacing: 0) {
            // Shared header area
            VStack(alignment: .leading, spacing: 12) {
                AnalyticsHeaderView(
                    selectedProjectName: selectedProjectName,
                    onClearProject: {
                        store.selectedAnalyticsProjectId = nil
                        store.recomputeAnalytics()
                    }
                )

                Picker("", selection: $selectedTab) {
                    ForEach(AnalyticsTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 12)

            // Tab content
            switch selectedTab {
            case .overview:
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
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
                                .help("Estimated from token usage")
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

            case .cache:
                CacheEffectivenessView(data: data.cacheAnalytics, dailyUsage: data.dailyUsage)

            case .models:
                ModelAnalysisView()
            }
        }
    }
}

// MARK: - Analytics Header

struct AnalyticsHeaderView: View {
    @Environment(SessionStore.self) private var store
    let selectedProjectName: String?
    let onClearProject: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("Analytics")
                .font(Typography.panelTitle)

            if let name = selectedProjectName {
                HStack(spacing: 4) {
                    Text(name)
                        .font(Typography.bodyMedium)
                    Button(action: onClearProject) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
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

struct TimeRangePicker: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Picker("", selection: $store.analyticsTimeRange) {
            ForEach(AnalyticsTimeRange.allCases, id: \.self) { range in
                Text(range.rawValue).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 280)
        .onChange(of: store.analyticsTimeRange) { _, _ in store.recomputeAnalytics() }

        if store.analyticsTimeRange == .custom {
            HStack(spacing: 4) {
                DatePicker("", selection: $store.analyticsCustomFrom, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.field)
                Text("to")
                    .font(.system(size: 12))
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
        CardView {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value)
                        .font(Typography.displayLarge)
                        .foregroundStyle(isHighlighted ? Color.orange : .primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

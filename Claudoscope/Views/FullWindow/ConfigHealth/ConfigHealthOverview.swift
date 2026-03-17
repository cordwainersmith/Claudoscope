import SwiftUI

// MARK: - Overview

struct HealthOverviewView: View {
    let lintResults: [LintResult]
    let lintSummary: LintSummary
    var isSecretScanLoading: Bool = false
    @Binding var selectedResultId: String?
    @Binding var hiddenSeverities: Set<LintSeverity>
    var selectedItem: String?
    var onRescan: (() -> Void)?
    @State private var viewMode: ViewMode = .byCategory
    @State private var collapsedCategories: Set<String> = []

    private var visibleResults: [LintResult] {
        var items = lintResults
        if !hiddenSeverities.isEmpty {
            items = items.filter { !hiddenSeverities.contains($0.severity) }
        }
        if let selectedItem {
            items = items.filter { ($0.displayPath ?? $0.filePath) == selectedItem }
        }
        return items
    }

    // Group by rule for "By Rule" view
    private var groupedByRule: [(checkId: LintCheckId, severity: LintSeverity, results: [LintResult])] {
        let dict = Dictionary(grouping: visibleResults, by: \.checkId)
        return dict.keys.sorted(by: { $0.rawValue < $1.rawValue }).compactMap { key in
            guard let items = dict[key], let first = items.first else { return nil }
            return (checkId: key, severity: first.severity, results: items)
        }
    }

    // Group by category for "By Category" view
    private var groupedByCategory: [(category: CategoryDef, rules: [(checkId: LintCheckId, severity: LintSeverity, results: [LintResult])])] {
        let dict = Dictionary(grouping: visibleResults) { categoryFor($0.checkId).id }
        var result: [(category: CategoryDef, rules: [(checkId: LintCheckId, severity: LintSeverity, results: [LintResult])])] = []

        let allCats = healthCategories + (dict.keys.contains("other") ? [otherCategory] : [])
        for cat in allCats.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            guard let items = dict[cat.id], !items.isEmpty else { continue }
            let byRule = Dictionary(grouping: items, by: \.checkId)
            let rules = byRule.keys.sorted(by: { $0.rawValue < $1.rawValue }).compactMap { key -> (checkId: LintCheckId, severity: LintSeverity, results: [LintResult])? in
                guard let ruleItems = byRule[key], let first = ruleItems.first else { return nil }
                return (checkId: key, severity: first.severity, results: ruleItems)
            }
            result.append((category: cat, rules: rules))
        }
        return result
    }

    // Visible summary (recalculated when filters are active)
    private var visibleSummary: LintSummary {
        if hiddenSeverities.isEmpty && selectedItem == nil { return lintSummary }
        return LintSummary.from(results: visibleResults)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Title bar
                HStack(spacing: 12) {
                    Text("Config Health")
                        .font(Typography.panelTitle)

                    if selectedItem != nil {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease")
                                .font(.system(size: 11))
                            Text("Filtered")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(Capsule())
                    }

                    Spacer()

                    Picker("", selection: $viewMode) {
                        ForEach(ViewMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)

                    if isSecretScanLoading {
                        HStack(spacing: 5) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Scanning secrets...")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let onRescan {
                        Button(action: onRescan) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Rescan")
                    }
                }
                .padding(.horizontal, 24)

                // Health strip: gauge + stat cards
                HStack(spacing: 12) {
                    HealthGaugeCard(summary: visibleSummary)
                        .frame(width: 160)

                    HealthStatCard(
                        label: "Errors",
                        count: visibleSummary.errorCount,
                        color: Color(red: 0.886, green: 0.294, blue: 0.290),
                        descriptor: errorDescriptor
                    )

                    HealthStatCard(
                        label: "Warnings",
                        count: visibleSummary.warningCount,
                        color: Color(red: 0.937, green: 0.624, blue: 0.153),
                        descriptor: warningDescriptor
                    )

                    HealthStatCard(
                        label: "Info",
                        count: visibleSummary.infoCount,
                        color: Color(red: 0.216, green: 0.541, blue: 0.867),
                        descriptor: infoDescriptor
                    )
                }
                .padding(.horizontal, 24)

                // Issue content
                VStack(alignment: .leading, spacing: 8) {
                    if visibleResults.isEmpty {
                        Text("All severities are hidden")
                            .font(Typography.body)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 40)
                    } else {
                        switch viewMode {
                        case .byCategory:
                            byCategoryContent
                        case .byRule:
                            byRuleContent
                        case .byFile:
                            byFileContent
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
            .padding(.vertical, 24)
        }
    }

    // Descriptors for stat cards
    private var errorDescriptor: String {
        let cats = Set(visibleResults.filter { $0.severity == .error }.map { categoryFor($0.checkId).label })
        return cats.sorted().joined(separator: ", ")
    }

    private var warningDescriptor: String {
        let cats = Set(visibleResults.filter { $0.severity == .warning }.map { categoryFor($0.checkId).label })
        return cats.sorted().joined(separator: ", ")
    }

    private var infoDescriptor: String {
        let cats = Set(visibleResults.filter { $0.severity == .info }.map { categoryFor($0.checkId).label })
        return cats.sorted().joined(separator: ", ")
    }

    // MARK: - By Category View

    @ViewBuilder
    private var byCategoryContent: some View {
        ForEach(groupedByCategory, id: \.category.id) { group in
            CategorySection(
                category: group.category,
                rules: group.rules,
                isCollapsed: collapsedCategories.contains(group.category.id),
                onToggle: {
                    if collapsedCategories.contains(group.category.id) {
                        collapsedCategories.remove(group.category.id)
                    } else {
                        collapsedCategories.insert(group.category.id)
                    }
                },
                onSelectResult: { selectedResultId = $0.id }
            )
        }
    }

    // MARK: - By Rule View (preserved from original)

    @ViewBuilder
    private var byRuleContent: some View {
        Text("ISSUES BY RULE")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.tertiary)

        VStack(spacing: 2) {
            ForEach(groupedByRule, id: \.checkId) { group in
                RuleGroupRow(
                    checkId: group.checkId,
                    severity: group.severity,
                    results: group.results,
                    onSelectResult: { selectedResultId = $0.id }
                )
            }
        }
    }

    // MARK: - By File View (preserved from original)

    @ViewBuilder
    private var byFileContent: some View {
        Text("ISSUES BY FILE")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.tertiary)

        VStack(spacing: 2) {
            ForEach(visibleResults) { result in
                FileResultRow(result: result) {
                    selectedResultId = result.id
                }
            }
        }
    }
}

// MARK: - Health Gauge Card

struct HealthGaugeCard: View {
    let summary: LintSummary

    private var percentage: Int { Int(summary.healthScore * 100) }

    private var label: String {
        if summary.healthScore >= 0.90 { return "Excellent" }
        if summary.healthScore >= 0.70 { return "Good" }
        if summary.healthScore >= 0.40 { return "Fair" }
        return "Poor"
    }

    private var gaugeColor: Color {
        if summary.healthScore >= 0.70 { return Color(red: 0.388, green: 0.600, blue: 0.133) }
        if summary.healthScore >= 0.40 { return Color(red: 0.937, green: 0.624, blue: 0.153) }
        return Color(red: 0.886, green: 0.294, blue: 0.290)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: summary.healthScore)
                    .stroke(gaugeColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 1) {
                    Text("\(percentage)%")
                        .font(.system(size: 18, weight: .medium, design: .monospaced))
                        .foregroundStyle(gaugeColor)
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 80, height: 80)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }
}

// MARK: - Health Stat Card

struct HealthStatCard: View {
    let label: String
    let count: Int
    let color: Color
    var descriptor: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Text("\(count)")
                .font(Typography.displayLarge)
                .foregroundStyle(count > 0 ? color : .primary)

            if !descriptor.isEmpty {
                Text(descriptor)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }
}

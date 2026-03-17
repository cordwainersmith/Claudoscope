import SwiftUI

// MARK: - Rule & Category Metadata

private struct RuleMetadata {
    let displayName: String
    let hint: String
}

private let ruleMetadata: [LintCheckId: RuleMetadata] = [
    .SEC001: RuleMetadata(
        displayName: "Private key detected",
        hint: "Private key material found in session output. Never paste private keys into prompts. Use file references or environment variables instead."
    ),
    .SEC002: RuleMetadata(
        displayName: "AWS access key detected",
        hint: "Found AWS access key pattern (AKIA...) in session output. Use environment variables or a secrets manager instead of hardcoding credentials."
    ),
    .SEC003: RuleMetadata(
        displayName: "Authorization header detected",
        hint: "Bearer token found in session content. Ensure auth headers are sourced from env vars, not pasted inline."
    ),
    .SEC004: RuleMetadata(
        displayName: "API key or token detected",
        hint: "Generic API key pattern matched. Rotate the key and move it to a .env file or secrets vault."
    ),
    .SEC005: RuleMetadata(
        displayName: "Password or secret literal detected",
        hint: "Plaintext password or secret found in session content. Use a secrets manager or environment variables."
    ),
    .SEC006: RuleMetadata(
        displayName: "Connection string with credentials",
        hint: "Database connection string with embedded credentials detected. Move credentials to environment variables."
    ),
    .SEC007: RuleMetadata(
        displayName: "Platform token detected",
        hint: "Platform-specific token (GitHub, Slack, npm, etc.) found. Rotate the token and store it securely."
    ),
    .SES001: RuleMetadata(
        displayName: "High cost session",
        hint: "Session estimated cost exceeds $25. Consider breaking expensive tasks into smaller sessions."
    ),
    .SES002: RuleMetadata(
        displayName: "Very long conversation",
        hint: "Session has an unusually high message count. Long sessions increase compaction frequency and degrade context quality."
    ),
    .SES003: RuleMetadata(
        displayName: "Runaway token consumption",
        hint: "Session exceeded expected token budget. Consider breaking the task into smaller sessions or adding a /compact checkpoint mid-flow."
    ),
    .SES004: RuleMetadata(
        displayName: "Stale session with history",
        hint: "Session has significant history but hasn't been active recently. Consider archiving or reviewing for relevant context."
    ),
    .SKL001: RuleMetadata(
        displayName: "Wrong SKILL.md casing",
        hint: "Skill manifest file should be named SKILL.md (uppercase). Rename to match expected convention."
    ),
    .SKL002: RuleMetadata(
        displayName: "Missing skill name",
        hint: "Skill YAML frontmatter is missing the 'name' field. Add a kebab-case name to the frontmatter."
    ),
    .SKL003: RuleMetadata(
        displayName: "Missing skill description",
        hint: "Skill YAML frontmatter is missing the 'description' field. Add a clear description of what the skill does."
    ),
    .SKL004: RuleMetadata(
        displayName: "Name/directory mismatch",
        hint: "Skill name in frontmatter doesn't match the containing directory name. Align them for consistency."
    ),
    .SKL005: RuleMetadata(
        displayName: "Name not kebab-case",
        hint: "Skill name should use kebab-case (lowercase with hyphens). Rename to match the convention."
    ),
    .SKL006: RuleMetadata(
        displayName: "Name exceeds 64 characters",
        hint: "Skill name is too long. Shorten it to 64 characters or fewer."
    ),
    .SKL007: RuleMetadata(
        displayName: "Description exceeds 1024 characters",
        hint: "Skill description is too long. Keep it concise, under 1024 characters."
    ),
    .SKL008: RuleMetadata(
        displayName: "XML brackets in frontmatter",
        hint: "Skill YAML frontmatter contains raw XML brackets which can break the system prompt parser. Escape them or move to the body."
    ),
    .SKL009: RuleMetadata(
        displayName: "Reserved word in skill name",
        hint: "Skill name uses a reserved word. Choose a different name to avoid conflicts."
    ),
    .SKL012: RuleMetadata(
        displayName: "Skill body exceeds 500 lines",
        hint: "Skill body is very long. Consider splitting into smaller, focused skills."
    ),
    .SKL_AGG: RuleMetadata(
        displayName: "Aggregate descriptions over budget",
        hint: "Combined skill descriptions exceed the 16,000 character budget. Trim descriptions to stay within limits."
    ),
    .CMD001: RuleMetadata(
        displayName: "CLAUDE.md exceeds 200 lines",
        hint: "Your CLAUDE.md is getting long. Consider splitting into a .claude/rules/ directory for better organization."
    ),
    .CMD002: RuleMetadata(
        displayName: "Large CLAUDE.md without rules directory",
        hint: "CLAUDE.md has over 100 lines but no .claude/rules/ directory. Split sections into separate rule files."
    ),
    .CMD003: RuleMetadata(
        displayName: "File-type patterns inline",
        hint: "File-type glob patterns found inline in CLAUDE.md. Move them to .claude/rules/ with proper glob frontmatter."
    ),
    .CMD006: RuleMetadata(
        displayName: "Unclosed code block",
        hint: "CLAUDE.md contains an unclosed code block (mismatched backtick fences). Close it to prevent parsing issues."
    ),
    .CMD_IMPORT: RuleMetadata(
        displayName: "Deep @import chain",
        hint: "Import chain exceeds 5 hops. Flatten imports to reduce complexity and improve readability."
    ),
    .CMD_DEPRECATE: RuleMetadata(
        displayName: ".claude/commands/ deprecated",
        hint: "The .claude/commands/ directory is deprecated. Migrate to .claude/rules/ for the new convention."
    ),
    .RUL001: RuleMetadata(
        displayName: "Malformed YAML frontmatter",
        hint: "Rule file has invalid YAML frontmatter. Check for syntax errors and fix the YAML."
    ),
    .RUL002: RuleMetadata(
        displayName: "Invalid glob syntax",
        hint: "Glob pattern in rule frontmatter has invalid syntax. Check for unmatched brackets or invalid characters."
    ),
    .RUL003: RuleMetadata(
        displayName: "Glob matches no files",
        hint: "The glob pattern in this rule doesn't match any files. Verify the pattern targets existing paths."
    ),
    .RUL005: RuleMetadata(
        displayName: "Rule exceeds 100 lines",
        hint: "Rule file is over 100 lines. Consider splitting into smaller, focused rules."
    ),
    .XCT001: RuleMetadata(
        displayName: "Config token estimate",
        hint: "Your CLAUDE.md and settings consume an estimated portion of the context window. Consider trimming if you see frequent compactions."
    ),
    .XCT002: RuleMetadata(
        displayName: "Config tokens exceed 5000",
        hint: "Configuration exceeds 5,000 tokens. This significantly reduces available context. Trim or split your config."
    ),
    .XCT003: RuleMetadata(
        displayName: "No .claude/ directory",
        hint: "No .claude/ directory found. Create one to configure Claude Code for this project."
    ),
]

private struct CategoryDef: Identifiable {
    let id: String
    let label: String
    let icon: String
    let color: Color
    let prefixes: [String]
    let sortOrder: Int
}

private let healthCategories: [CategoryDef] = [
    CategoryDef(id: "security", label: "Security", icon: "!", color: Color(red: 0.886, green: 0.294, blue: 0.290), prefixes: ["SEC"], sortOrder: 1),
    CategoryDef(id: "performance", label: "Session performance", icon: "~", color: Color(red: 0.937, green: 0.624, blue: 0.153), prefixes: ["SES"], sortOrder: 2),
    CategoryDef(id: "skills", label: "Skills & hooks", icon: "S", color: Color(red: 0.498, green: 0.467, blue: 0.867), prefixes: ["SKL", "HKS"], sortOrder: 3),
    CategoryDef(id: "config", label: "Configuration", icon: "i", color: Color(red: 0.216, green: 0.541, blue: 0.867), prefixes: ["XCT", "CFG", "CMD", "RUL"], sortOrder: 4),
]

private let otherCategory = CategoryDef(id: "other", label: "Other", icon: "?", color: .gray, prefixes: [], sortOrder: 99)

private func categoryFor(_ checkId: LintCheckId) -> CategoryDef {
    let raw = checkId.rawValue
    for cat in healthCategories {
        for prefix in cat.prefixes {
            if raw.hasPrefix(prefix) { return cat }
        }
    }
    return otherCategory
}

private func displayNameFor(_ checkId: LintCheckId) -> String {
    ruleMetadata[checkId]?.displayName ?? checkId.rawValue
}

private func hintFor(_ checkId: LintCheckId) -> String? {
    ruleMetadata[checkId]?.hint
}

// MARK: - Sidebar

struct ConfigHealthSidebarContent: View {
    let filterText: String
    let lintResults: [LintResult]
    let lintSummary: LintSummary
    let isLoading: Bool
    @Binding var selectedItem: String?
    @Binding var hiddenSeverities: Set<LintSeverity>

    private var filtered: [LintResult] {
        var items = lintResults
        if !hiddenSeverities.isEmpty {
            items = items.filter { !hiddenSeverities.contains($0.severity) }
        }
        if !filterText.isEmpty {
            items = items.filter { result in
                let display = result.displayPath ?? result.filePath
                return display.localizedCaseInsensitiveContains(filterText) ||
                    displayNameFor(result.checkId).localizedCaseInsensitiveContains(filterText)
            }
        }
        return items
    }

    // Group items by displayPath, find highest severity per group
    private var itemGroups: [(name: String, count: Int, highestSeverity: LintSeverity)] {
        let dict = Dictionary(grouping: filtered) { $0.displayPath ?? $0.filePath }
        return dict.map { key, results in
            let highest = results.map(\.severity).min() ?? .info // .error < .warning < .info
            return (name: key, count: results.count, highestSeverity: highest)
        }
    }

    // Items grouped under severity tiers
    private var errorItems: [(name: String, count: Int, highestSeverity: LintSeverity)] {
        itemGroups.filter { $0.highestSeverity == .error }.sorted { $0.count > $1.count }
    }

    private var warningItems: [(name: String, count: Int, highestSeverity: LintSeverity)] {
        itemGroups.filter { $0.highestSeverity == .warning }.sorted { $0.count > $1.count }
    }

    private var infoItems: [(name: String, count: Int, highestSeverity: LintSeverity)] {
        itemGroups.filter { $0.highestSeverity == .info }.sorted { $0.count > $1.count }
    }

    var body: some View {
        if isLoading {
            VStack(spacing: 8) {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Text("Scanning...")
                    .font(Typography.body)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        } else if lintResults.isEmpty {
            SidebarEmptyStateView(
                icon: "checkmark.shield",
                text: "No issues found"
            )
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Severity filter pills
                SeverityFilterPills(
                    summary: lintSummary,
                    hiddenSeverities: $hiddenSeverities
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                Divider()
                    .padding(.horizontal, 12)

                if filtered.isEmpty {
                    SidebarEmptyStateView(
                        icon: "line.3.horizontal.decrease",
                        text: "No matching results"
                    )
                } else {
                    // Clear filter option
                    if selectedItem != nil {
                        Button {
                            selectedItem = nil
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                                Text("Clear filter")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }

                    // Severity-grouped item list
                    if !errorItems.isEmpty && !hiddenSeverities.contains(.error) {
                        SeveritySection(
                            label: "Critical issues",
                            severity: .error,
                            items: errorItems,
                            selectedItem: $selectedItem
                        )
                    }

                    if !warningItems.isEmpty && !hiddenSeverities.contains(.warning) {
                        if !errorItems.isEmpty && !hiddenSeverities.contains(.error) {
                            Divider()
                                .padding(.horizontal, 12)
                                .padding(.vertical, 2)
                        }
                        SeveritySection(
                            label: "Warnings",
                            severity: .warning,
                            items: warningItems,
                            selectedItem: $selectedItem
                        )
                    }

                    if !infoItems.isEmpty && !hiddenSeverities.contains(.info) {
                        if (!errorItems.isEmpty && !hiddenSeverities.contains(.error)) ||
                            (!warningItems.isEmpty && !hiddenSeverities.contains(.warning)) {
                            Divider()
                                .padding(.horizontal, 12)
                                .padding(.vertical, 2)
                        }
                        SeveritySection(
                            label: "Info",
                            severity: .info,
                            items: infoItems,
                            selectedItem: $selectedItem
                        )
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Sidebar Components

private struct SeverityFilterPills: View {
    let summary: LintSummary
    @Binding var hiddenSeverities: Set<LintSeverity>

    var body: some View {
        HStack(spacing: 6) {
            FilterPill(
                label: "Errors",
                count: summary.errorCount,
                color: Color(red: 0.886, green: 0.294, blue: 0.290),
                isActive: !hiddenSeverities.contains(.error)
            ) {
                toggleSeverity(.error)
            }

            FilterPill(
                label: "Warnings",
                count: summary.warningCount,
                color: Color(red: 0.937, green: 0.624, blue: 0.153),
                isActive: !hiddenSeverities.contains(.warning)
            ) {
                toggleSeverity(.warning)
            }

            FilterPill(
                label: "Info",
                count: summary.infoCount,
                color: Color(red: 0.216, green: 0.541, blue: 0.867),
                isActive: !hiddenSeverities.contains(.info)
            ) {
                toggleSeverity(.info)
            }

            Spacer()
        }
    }

    private func toggleSeverity(_ severity: LintSeverity) {
        if hiddenSeverities.contains(severity) {
            hiddenSeverities.remove(severity)
        } else {
            hiddenSeverities.insert(severity)
        }
    }
}

private struct FilterPill: View {
    let label: String
    let count: Int
    let color: Color
    let isActive: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text("\(count)")
                    .font(.system(size: 10, weight: isActive ? .semibold : .regular, design: .monospaced))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isActive ? color.opacity(0.1) : Color.clear)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(isActive ? color.opacity(0.4) : Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .opacity(isActive ? 1.0 : 0.5)
        }
        .buttonStyle(.plain)
        .help(isActive ? "Hide \(label.lowercased())" : "Show \(label.lowercased())")
    }
}

private struct SeveritySection: View {
    let label: String
    let severity: LintSeverity
    let items: [(name: String, count: Int, highestSeverity: LintSeverity)]
    @Binding var selectedItem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            HStack(spacing: 6) {
                Circle()
                    .fill(colorForSeverity(severity))
                    .frame(width: 6, height: 6)
                Text(label.uppercased())
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)

            // Item rows
            ForEach(items, id: \.name) { item in
                SidebarItemRow(
                    name: item.name,
                    count: item.count,
                    isSelected: selectedItem == item.name
                ) {
                    if selectedItem == item.name {
                        selectedItem = nil
                    } else {
                        selectedItem = item.name
                    }
                }
            }
        }
    }
}

private struct SidebarItemRow: View {
    let name: String
    let count: Int
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Text(name)
                    .font(Typography.body)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)

                Spacer()

                Text("\(count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.08)
                    : (isHovered ? Color.primary.opacity(0.04) : .clear)
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Main Panel

struct ConfigHealthMainPanelView: View {
    let lintResults: [LintResult]
    let lintSummary: LintSummary
    let isLoading: Bool
    var isSecretScanLoading: Bool = false
    @Binding var selectedResultId: String?
    @Binding var hiddenSeverities: Set<LintSeverity>
    var selectedItem: String? = nil
    var onRescan: (() -> Void)?
    var onNavigateToSession: ((String, String) -> Void)?

    private var selectedResult: LintResult? {
        guard let id = selectedResultId else { return nil }
        return lintResults.first(where: { $0.id == id })
    }

    var body: some View {
        if isLoading {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                Text("Running config health checks...")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result = selectedResult {
            HealthResultDetailView(result: result, onNavigateToSession: onNavigateToSession) {
                selectedResultId = nil
            }
        } else if lintResults.isEmpty {
            EmptyStateView(
                icon: "checkmark.shield",
                title: "No issues found",
                message: "Your configuration looks healthy. All checks passed."
            )
        } else {
            HealthOverviewView(
                lintResults: lintResults,
                lintSummary: lintSummary,
                isSecretScanLoading: isSecretScanLoading,
                selectedResultId: $selectedResultId,
                hiddenSeverities: $hiddenSeverities,
                selectedItem: selectedItem,
                onRescan: onRescan
            )
        }
    }
}

// MARK: - View Mode

private enum ViewMode: String, CaseIterable {
    case byCategory = "By Category"
    case byRule = "By Rule"
    case byFile = "By File"
}

// MARK: - Overview

private struct HealthOverviewView: View {
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
                                .font(.system(size: 9))
                            Text("Filtered")
                                .font(.system(size: 10, weight: .medium))
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
                                .font(.system(size: 11))
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
            .font(.system(size: 11, weight: .medium))
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
            .font(.system(size: 11, weight: .medium))
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

private struct HealthGaugeCard: View {
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
                        .font(.system(size: 10))
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

private struct HealthStatCard: View {
    let label: String
    let count: Int
    let color: Color
    var descriptor: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text("\(count)")
                .font(Typography.displayLarge)
                .foregroundStyle(count > 0 ? color : .primary)

            if !descriptor.isEmpty {
                Text(descriptor)
                    .font(.system(size: 11))
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

// MARK: - Category Section

private struct CategorySection: View {
    let category: CategoryDef
    let rules: [(checkId: LintCheckId, severity: LintSeverity, results: [LintResult])]
    let isCollapsed: Bool
    let onToggle: () -> Void
    let onSelectResult: (LintResult) -> Void

    private var totalResults: Int {
        rules.reduce(0) { $0 + $1.results.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Category header
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    // Icon square
                    Text(category.icon)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(category.color)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    Text(category.label)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)

                    Text("\(rules.count) \(rules.count == 1 ? "rule" : "rules"), \(totalResults) \(totalResults == 1 ? "item" : "items")")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)

                    Spacer()

                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Issue rows
            if !isCollapsed {
                VStack(spacing: 2) {
                    ForEach(rules, id: \.checkId) { rule in
                        CategoryIssueRow(
                            checkId: rule.checkId,
                            severity: rule.severity,
                            results: rule.results,
                            onSelectResult: onSelectResult
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Category Issue Row

private struct CategoryIssueRow: View {
    let checkId: LintCheckId
    let severity: LintSeverity
    let results: [LintResult]
    let onSelectResult: (LintResult) -> Void
    @State private var isExpanded = false

    private var scopeLabel: String {
        let raw = checkId.rawValue
        let unit = (raw.hasPrefix("SES") || raw.hasPrefix("SEC")) ? "session" : "file"
        return "\(results.count) \(results.count == 1 ? unit : unit + "s")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if results.count == 1 {
                    onSelectResult(results[0])
                } else {
                    withAnimation(.easeInOut(duration: Motion.quick)) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                HStack(alignment: .top, spacing: 0) {
                    // Left column: name + hint
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(colorForSeverity(severity))
                                .frame(width: 8, height: 8)
                                .padding(.top, 2)

                            Text(displayNameFor(checkId))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.primary)
                        }

                        if let hint = hintFor(checkId) {
                            Text(hint)
                                .font(Typography.body)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .padding(.leading, 16)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Right column: scope + action
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(scopeLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)

                        if results.count > 1 {
                            HStack(spacing: 3) {
                                Text(isExpanded ? "Collapse" : "View all")
                                    .font(.system(size: 11))
                                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 8))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(AnyShapeStyle(.quaternary))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            HStack(spacing: 3) {
                                Text("View")
                                    .font(.system(size: 11))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8))
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 12)
                }
                .padding(12)
                .background(Color.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.md)
                        .strokeBorder(.quaternary, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded sub-list of affected items
            if isExpanded && results.count > 1 {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(results) { result in
                        Button { onSelectResult(result) } label: {
                            HStack(spacing: 8) {
                                Text(result.displayPath ?? (result.filePath as NSString).lastPathComponent)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Spacer()

                                SessionBadgeView(result: result)

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.quaternary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.leading, 16)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
                .background(Color.cardBackground.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                .padding(.top, 1)
            }
        }
    }
}

// MARK: - By-Rule Group Row (preserved)

private struct RuleGroupRow: View {
    let checkId: LintCheckId
    let severity: LintSeverity
    let results: [LintResult]
    let onSelectResult: (LintResult) -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if results.count == 1 {
                    onSelectResult(results[0])
                } else {
                    withAnimation(.easeInOut(duration: Motion.quick)) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: severityIcon(severity))
                        .font(.system(size: 10))
                        .foregroundStyle(colorForSeverity(severity))

                    Text(displayNameFor(checkId))
                        .font(Typography.body)
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    Spacer()

                    Text({
                        let raw = checkId.rawValue
                        let unit = (raw.hasPrefix("SES") || raw.hasPrefix("SEC")) ? "session" : "file"
                        return "\(results.count) \(results.count == 1 ? unit : unit + "s")"
                    }())
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    if results.count > 1 {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.quaternary)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.quaternary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.md)
                        .strokeBorder(.quaternary, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded && results.count > 1 {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(results) { result in
                        Button { onSelectResult(result) } label: {
                            HStack(spacing: 8) {
                                Text(result.displayPath ?? (result.filePath as NSString).lastPathComponent)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Spacer()

                                SessionBadgeView(result: result)

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.quaternary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.leading, 24)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
                .background(Color.cardBackground.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                .padding(.top, 1)
            }
        }
    }
}

// MARK: - By-File Result Row (preserved)

private struct FileResultRow: View {
    let result: LintResult
    let onSelect: () -> Void

    private var displayName: String {
        result.displayPath ?? (result.filePath as NSString).lastPathComponent
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: severityIcon(result.severity))
                    .font(.system(size: 10))
                    .foregroundStyle(colorForSeverity(result.severity))

                Text(displayNameFor(result.checkId))
                    .font(Typography.body)
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                Spacer()

                SessionBadgeView(result: result)

                Text(displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                if let line = result.line {
                    Text("L\(line)")
                        .font(Typography.codeSmall)
                        .foregroundStyle(.tertiary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Detail View

private struct HealthResultDetailView: View {
    let result: LintResult
    var onNavigateToSession: ((String, String) -> Void)?
    let onBack: () -> Void
    @State private var showUnmasked = false

    private var isSecretResult: Bool {
        result.checkId.rawValue.hasPrefix("SEC")
    }

    private var isSessionResult: Bool {
        result.filePath.hasPrefix("sessions/")
    }

    private var sessionIds: (projectId: String, sessionId: String)? {
        guard isSessionResult else { return nil }
        let parts = result.filePath.split(separator: "/")
        guard parts.count >= 3 else { return nil }
        return (projectId: String(parts[1]), sessionId: String(parts[2]))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Back button
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .medium))
                        Text("Back to overview")
                            .font(Typography.body)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)

                // Severity + display name header
                HStack(spacing: 10) {
                    SeverityBadge(severity: result.severity)

                    Text(displayNameFor(result.checkId))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)

                    Spacer()
                }
                .padding(.horizontal, 24)

                // File/Session path card
                VStack(alignment: .leading, spacing: 8) {
                    Text(isSessionResult ? "SESSION" : "FILE")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: isSessionResult ? "bubble.left.and.text.bubble.right" : "doc.text")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(isSessionResult ? (result.displayPath ?? result.filePath) : result.filePath)
                                .font(.system(size: 12, design: isSessionResult ? .default : .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }

                        if !isSessionResult, let line = result.line {
                            HStack(spacing: 6) {
                                Image(systemName: "number")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Text("Line \(line)")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if isSessionResult, let ids = sessionIds, let onNavigateToSession {
                            Button {
                                onNavigateToSession(ids.projectId, ids.sessionId)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.right.circle")
                                        .font(.system(size: 11))
                                    Text("View Session")
                                        .font(Typography.bodyMedium)
                                }
                                .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 4)
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
                .padding(.horizontal, 24)

                // Remediation hint card
                if let hint = hintFor(result.checkId) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("REMEDIATION")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)

                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "lightbulb")
                                .font(.system(size: 13))
                                .foregroundStyle(.yellow)

                            Text(hint)
                                .font(Typography.body)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
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
                    .padding(.horizontal, 24)
                }

                // Message card
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("DETAILS")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)

                        Spacer()

                        if isSecretResult, result.unmaskedSecret != nil {
                            Button {
                                showUnmasked.toggle()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: showUnmasked ? "eye.slash" : "eye")
                                        .font(.system(size: 11))
                                    Text(showUnmasked ? "Hide" : "Reveal")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text(displayMessage(for: result))
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)

                        // Show unmasked secret value
                        if isSecretResult, showUnmasked, let secret = result.unmaskedSecret {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.shield")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.red)
                                Text(secret)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.md)
                                    .strokeBorder(Color.red.opacity(0.2), lineWidth: 1)
                            )
                        }

                        // Context lines from the JSONL
                        if let context = result.contextLines, !context.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(context.enumerated()), id: \.offset) { idx, line in
                                    Text(line)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(idx == context.count - 1 ? Color.orange.opacity(0.06) : .clear)

                                    if idx < context.count - 1 {
                                        Divider()
                                            .padding(.horizontal, 10)
                                    }
                                }
                            }
                            .background(AnyShapeStyle(.quaternary).opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.md)
                                    .strokeBorder(.quaternary, lineWidth: 1)
                            )
                        }

                        let badges = sessionBadges(for: result)
                        if !badges.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(badges, id: \.text) { badge in
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(badge.color)
                                            .frame(width: 6, height: 6)
                                        Text(badge.text)
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                            .foregroundStyle(badge.color)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(badge.color.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                                }
                            }
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
                .padding(.horizontal, 24)

                // Legacy fix suggestion (if present and different from hint)
                if let fix = result.fix, fix != hintFor(result.checkId) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SUGGESTED FIX")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)

                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "wrench")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)

                            Text(fix)
                                .font(Typography.body)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
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
                    .padding(.horizontal, 24)
                }
            }
            .padding(.vertical, 24)
        }
    }
}

private struct SeverityBadge: View {
    let severity: LintSeverity

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: severityIcon(severity))
                .font(.system(size: 10))
                .foregroundStyle(colorForSeverity(severity))
            Text(severity.rawValue.capitalized)
                .font(Typography.bodyMedium)
                .foregroundStyle(colorForSeverity(severity))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(colorForSeverity(severity).opacity(0.12))
        .clipShape(Capsule())
    }
}

// MARK: - Helpers

private func colorForSeverity(_ severity: LintSeverity) -> Color {
    switch severity {
    case .error: return Color(red: 0.886, green: 0.294, blue: 0.290)
    case .warning: return Color(red: 0.937, green: 0.624, blue: 0.153)
    case .info: return Color(red: 0.216, green: 0.541, blue: 0.867)
    }
}

private func severityIcon(_ severity: LintSeverity) -> String {
    switch severity {
    case .error: return "exclamationmark.triangle.fill"
    case .warning: return "exclamationmark.diamond.fill"
    case .info: return "info.circle.fill"
    }
}

private func displayMessage(for result: LintResult) -> String {
    let raw = result.checkId.rawValue
    guard raw.hasPrefix("SES"),
          let tagRange = result.message.range(of: " \\[\\$[^\\]]+\\]$", options: .regularExpression) else {
        return result.message
    }
    return String(result.message[result.message.startIndex..<tagRange.lowerBound])
}

private func sessionBadges(for result: LintResult) -> [(text: String, color: Color)] {
    guard result.checkId.rawValue.hasPrefix("SES") else { return [] }
    guard let tagRange = result.message.range(of: "\\[\\$[^\\]]+\\]$", options: .regularExpression) else { return [] }
    let tag = String(result.message[tagRange].dropFirst().dropLast())
    let parts = tag.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count == 3 else { return [] }

    var badges: [(String, Color)] = []
    badges.append((parts[1], .cyan))
    badges.append((parts[2], .purple))
    return badges
}

@ViewBuilder
private func SessionBadgeView(result: LintResult) -> some View {
    let badges = sessionBadges(for: result)
    if !badges.isEmpty {
        HStack(spacing: 4) {
            ForEach(badges, id: \.text) { badge in
                Text(badge.text)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(badge.color)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(badge.color.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
        }
    }
}

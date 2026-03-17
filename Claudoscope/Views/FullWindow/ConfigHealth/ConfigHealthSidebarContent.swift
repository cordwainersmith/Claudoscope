import SwiftUI

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
                                    .font(.system(size: 11))
                                Text("Clear filter")
                                    .font(.system(size: 12, weight: .medium))
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

struct SeverityFilterPills: View {
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

struct FilterPill: View {
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
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular, design: .monospaced))
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

struct SeveritySection: View {
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

struct SidebarItemRow: View {
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
                    .font(.system(size: 11))
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

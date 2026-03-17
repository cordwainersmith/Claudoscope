import SwiftUI

// MARK: - Sidebar

struct ConfigHealthSidebarContent: View {
    let filterText: String
    let lintResults: [LintResult]
    let lintSummary: LintSummary
    let isLoading: Bool
    @Binding var selectedResultId: String?
    let hiddenSeverities: Set<LintSeverity>

    private var filtered: [LintResult] {
        var items = lintResults
        if !hiddenSeverities.isEmpty {
            items = items.filter { !hiddenSeverities.contains($0.severity) }
        }
        if !filterText.isEmpty {
            items = items.filter { result in
                let display = result.displayPath ?? result.filePath
                return display.localizedCaseInsensitiveContains(filterText) ||
                    result.message.localizedCaseInsensitiveContains(filterText) ||
                    result.checkId.rawValue.localizedCaseInsensitiveContains(filterText)
            }
        }
        return items
    }

    private var groupedByFile: [(file: String, results: [LintResult])] {
        let dict = Dictionary(grouping: filtered) { $0.displayPath ?? $0.filePath }
        return dict.keys.sorted().map { key in
            (file: key, results: dict[key]!)
        }
    }

    var body: some View {
        if isLoading {
            VStack(spacing: 8) {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Text("Scanning...")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        } else if filtered.isEmpty {
            HealthEmptyList(
                icon: "checkmark.shield",
                text: lintResults.isEmpty ? "No issues found" : "No matching results"
            )
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Summary bar
                HealthSummarySidebarBar(summary: lintSummary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                Divider()
                    .padding(.horizontal, 12)

                // Grouped results
                ForEach(groupedByFile, id: \.file) { group in
                    HealthFileGroup(
                        displayName: group.file,
                        results: group.results,
                        selectedResultId: $selectedResultId
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Sidebar Components

private struct HealthSummarySidebarBar: View {
    let summary: LintSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                SeverityCount(color: .red, count: summary.errorCount, label: "E")
                SeverityCount(color: .orange, count: summary.warningCount, label: "W")
                SeverityCount(color: .blue, count: summary.infoCount, label: "I")
                Spacer()
            }

            HStack(spacing: 4) {
                Text("Health:")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("\(Int(summary.healthScore * 100))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(healthScoreColor(summary.healthScore))
            }
        }
    }
}

private struct SeverityCount: View {
    let color: Color
    let count: Int
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text("\(count)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }
}

private struct HealthFileGroup: View {
    let displayName: String
    let results: [LintResult]
    @Binding var selectedResultId: String?
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)

                    Text(displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)

                    Spacer()

                    Text("\(results.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(results) { result in
                    HealthResultRow(
                        result: result,
                        isSelected: selectedResultId == result.id
                    ) {
                        selectedResultId = result.id
                    }
                }
            }
        }
    }
}

private struct HealthResultRow: View {
    let result: LintResult
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Circle()
                    .fill(colorForSeverity(result.severity))
                    .frame(width: 7, height: 7)

                Text(result.checkId.rawValue)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(isSelected ? AnyShapeStyle(.white.opacity(0.2)) : AnyShapeStyle(.quaternary))
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                Text(displayMessage(for: result))
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .white : .primary)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.leading, 18)
            .padding(.vertical, 5)
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

struct ConfigHealthMainPanelView: View {
    let lintResults: [LintResult]
    let lintSummary: LintSummary
    let isLoading: Bool
    @Binding var selectedResultId: String?
    @Binding var hiddenSeverities: Set<LintSeverity>
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
                selectedResultId: $selectedResultId,
                hiddenSeverities: $hiddenSeverities,
                onRescan: onRescan
            )
        }
    }
}

// MARK: - Group Mode

private enum GroupMode: String, CaseIterable {
    case byRule = "By Rule"
    case byFile = "By File"
}

// MARK: - Overview

private struct HealthOverviewView: View {
    let lintResults: [LintResult]
    let lintSummary: LintSummary
    @Binding var selectedResultId: String?
    @Binding var hiddenSeverities: Set<LintSeverity>
    var onRescan: (() -> Void)?
    @State private var groupMode: GroupMode = .byRule

    private var visibleResults: [LintResult] {
        if hiddenSeverities.isEmpty { return lintResults }
        return lintResults.filter { !hiddenSeverities.contains($0.severity) }
    }

    private var groupedByRule: [(checkId: LintCheckId, severity: LintSeverity, message: String, results: [LintResult])] {
        let dict = Dictionary(grouping: visibleResults, by: \.checkId)
        return dict.keys.sorted(by: { $0.rawValue < $1.rawValue }).compactMap { key in
            guard let items = dict[key], let first = items.first else { return nil }
            return (checkId: key, severity: first.severity, message: first.message, results: items)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header row
                HStack(spacing: 12) {
                    Text("Config Health")
                        .font(.system(size: 18, weight: .medium))

                    Spacer()

                    // Group mode picker
                    Picker("", selection: $groupMode) {
                        ForEach(GroupMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)

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

                // Summary cards
                HStack(spacing: 12) {
                    HealthScoreCard(summary: lintSummary)

                    HealthSeverityStatCard(
                        title: "Errors",
                        count: lintSummary.errorCount,
                        color: .red,
                        isHidden: hiddenSeverities.contains(.error)
                    ) {
                        toggleSeverity(.error)
                    }

                    HealthSeverityStatCard(
                        title: "Warnings",
                        count: lintSummary.warningCount,
                        color: .orange,
                        isHidden: hiddenSeverities.contains(.warning)
                    ) {
                        toggleSeverity(.warning)
                    }

                    HealthSeverityStatCard(
                        title: "Info",
                        count: lintSummary.infoCount,
                        color: .blue,
                        isHidden: hiddenSeverities.contains(.info)
                    ) {
                        toggleSeverity(.info)
                    }
                }
                .padding(.horizontal, 24)

                // Results list
                VStack(alignment: .leading, spacing: 8) {
                    if visibleResults.isEmpty {
                        Text("All severities are hidden")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 40)
                    } else if groupMode == .byRule {
                        byRuleContent
                    } else {
                        byFileContent
                    }
                }
                .padding(.horizontal, 24)
            }
            .padding(.vertical, 24)
        }
    }

    @ViewBuilder
    private var byRuleContent: some View {
        Text("ISSUES BY RULE")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)

        VStack(spacing: 2) {
            ForEach(groupedByRule, id: \.checkId) { group in
                HealthRuleGroupRow(
                    checkId: group.checkId,
                    severity: group.severity,
                    message: group.message,
                    results: group.results,
                    onSelectResult: { selectedResultId = $0.id }
                )
            }
        }
    }

    @ViewBuilder
    private var byFileContent: some View {
        Text("ALL ISSUES")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)

        VStack(spacing: 2) {
            ForEach(visibleResults) { result in
                HealthOverviewResultRow(result: result) {
                    selectedResultId = result.id
                }
            }
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

// MARK: - Health Score Card

private struct HealthScoreCard: View {
    let summary: LintSummary

    private var percentage: Int { Int(summary.healthScore * 100) }

    private var label: String {
        if summary.healthScore >= 0.95 { return "Excellent" }
        if summary.healthScore >= 0.80 { return "Good" }
        if summary.healthScore >= 0.50 { return "Fair" }
        return "Poor"
    }

    private var totalFiles: Int {
        // Approximate unique file count from the summary counts
        summary.errorCount + summary.warningCount + summary.infoCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Health Score")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(healthScoreColor(summary.healthScore))
                Text("\(percentage)%")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if totalFiles > 0 {
                Text("\(summary.errorCount) errors, \(summary.warningCount) warnings")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
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

// MARK: - Severity Stat Card (clickable filter)

private struct HealthSeverityStatCard: View {
    let title: String
    let count: Int
    let color: Color
    let isHidden: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isHidden {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                    Text("\(count)")
                        .font(.system(size: 22, weight: .medium, design: .monospaced))
                        .foregroundStyle(count > 0 ? color : .primary)
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
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isHidden ? color.opacity(0.3) : .clear, lineWidth: 1.5)
            )
            .opacity(isHidden ? 0.4 : 1.0)
        }
        .buttonStyle(.plain)
        .help(isHidden ? "Show \(title.lowercased())" : "Hide \(title.lowercased())")
    }
}

// MARK: - By-Rule Group Row

private struct HealthRuleGroupRow: View {
    let checkId: LintCheckId
    let severity: LintSeverity
    let message: String
    let results: [LintResult]
    let onSelectResult: (LintResult) -> Void
    @State private var isExpanded = false

    private var affectedNames: [String] {
        results.map { $0.displayPath ?? ($0.filePath as NSString).lastPathComponent }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if results.count == 1 {
                    onSelectResult(results[0])
                } else {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(colorForSeverity(severity))
                        .frame(width: 8, height: 8)

                    Text(checkId.rawValue)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(AnyShapeStyle(.quaternary))
                        .clipShape(RoundedRectangle(cornerRadius: 3))

                    Text(ruleDescription(for: checkId))
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    Spacer()

                    Text({
                        let unit = checkId.rawValue.hasPrefix("SES") ? "session" : "file"
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
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
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
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(.top, 1)
            }
        }
    }
}

// MARK: - By-File Result Row

private struct HealthOverviewResultRow: View {
    let result: LintResult
    let onSelect: () -> Void

    private var displayName: String {
        result.displayPath ?? (result.filePath as NSString).lastPathComponent
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Circle()
                    .fill(colorForSeverity(result.severity))
                    .frame(width: 8, height: 8)

                Text(result.checkId.rawValue)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(AnyShapeStyle(.quaternary))
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                Text(displayMessage(for: result))
                    .font(.system(size: 12))
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
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
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
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)

                // Severity + Check ID header
                HStack(spacing: 10) {
                    SeverityBadge(severity: result.severity)

                    Text(result.checkId.rawValue)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(AnyShapeStyle(.quaternary))
                        .clipShape(RoundedRectangle(cornerRadius: 4))

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
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 4)
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
                .padding(.horizontal, 24)

                // Message card
                VStack(alignment: .leading, spacing: 8) {
                    Text("MESSAGE")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)

                    VStack(alignment: .leading, spacing: 10) {
                        Text(displayMessage(for: result))
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)

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
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
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
                .padding(.horizontal, 24)

                // Fix suggestion card
                if let fix = result.fix {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SUGGESTED FIX")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)

                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "lightbulb")
                                .font(.system(size: 13))
                                .foregroundStyle(.yellow)

                            Text(fix)
                                .font(.system(size: 12))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
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
            Circle()
                .fill(colorForSeverity(severity))
                .frame(width: 8, height: 8)
            Text(severity.rawValue.capitalized)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(colorForSeverity(severity))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(colorForSeverity(severity).opacity(0.12))
        .clipShape(Capsule())
    }
}

// MARK: - Helpers

private struct HealthEmptyList: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(.quaternary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

private func colorForSeverity(_ severity: LintSeverity) -> Color {
    switch severity {
    case .error: return .red
    case .warning: return .orange
    case .info: return .blue
    }
}

private func healthScoreColor(_ score: Double) -> Color {
    if score >= 0.8 { return .green }
    if score >= 0.5 { return .orange }
    return .red
}

private func displayMessage(for result: LintResult) -> String {
    guard result.checkId.rawValue.hasPrefix("SES"),
          let tagRange = result.message.range(of: " \\[\\$[^\\]]+\\]$", options: .regularExpression) else {
        return result.message
    }
    return String(result.message[result.message.startIndex..<tagRange.lowerBound])
}

private func sessionBadges(for result: LintResult) -> [(text: String, color: Color)] {
    guard result.checkId.rawValue.hasPrefix("SES") else { return [] }
    // Parse stats tag: [$X.XX | NK tokens | N msgs]
    guard let tagRange = result.message.range(of: "\\[\\$[^\\]]+\\]$", options: .regularExpression) else { return [] }
    let tag = String(result.message[tagRange].dropFirst().dropLast()) // remove [ ]
    let parts = tag.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count == 3 else { return [] }

    var badges: [(String, Color)] = []
    badges.append((parts[1], .cyan))          // NK tokens
    badges.append((parts[2], .purple))        // N msgs
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

private func ruleDescription(for checkId: LintCheckId) -> String {
    switch checkId {
    case .CMD001: return "CLAUDE.md exceeds 200 lines"
    case .CMD002: return "Large CLAUDE.md without rules directory"
    case .CMD003: return "File-type patterns inline"
    case .CMD006: return "Unclosed code block"
    case .CMD_IMPORT: return "Deep @import chain"
    case .CMD_DEPRECATE: return ".claude/commands/ deprecated"
    case .RUL001: return "Malformed YAML frontmatter"
    case .RUL002: return "Invalid glob syntax"
    case .RUL003: return "Glob matches no files"
    case .RUL005: return "Rule exceeds 100 lines"
    case .SKL001: return "Wrong SKILL.md casing"
    case .SKL002: return "Missing skill name"
    case .SKL003: return "Missing skill description"
    case .SKL004: return "Name/directory mismatch"
    case .SKL005: return "Name not kebab-case"
    case .SKL006: return "Name exceeds 64 chars"
    case .SKL007: return "Description exceeds 1024 chars"
    case .SKL008: return "XML brackets in frontmatter"
    case .SKL009: return "Reserved word in name"
    case .SKL012: return "Skill body exceeds 500 lines"
    case .SKL_AGG: return "Aggregate descriptions over budget"
    case .XCT001: return "Config token estimate"
    case .XCT002: return "Config tokens exceed 5000"
    case .XCT003: return "No .claude/ directory"
    case .SES001: return "High cost session"
    case .SES002: return "Very long conversation"
    case .SES003: return "Runaway token consumption"
    case .SES004: return "Stale session with history"
    }
}

import SwiftUI

// MARK: - Hardening Sidebar Content

/// Two-item sidebar: "Overview" (default) and a collapsible "Lint Issues" group
/// scoped to HRD* lint results, with severity counts. Selecting Overview clears
/// the lint-result selection so the main panel shows the install/score view.
/// Selecting an issue under Lint Issues drills into the same detail view used
/// by the Config Health rail.
struct HardeningSidebarContent: View {
    let filterText: String
    let lintResults: [LintResult]
    let isLoading: Bool
    @Binding var selectedLintResultId: String?

    @State private var lintIssuesExpanded: Bool = true

    private var hrdResults: [LintResult] {
        let scoped = lintResults.filter { $0.checkId.rawValue.hasPrefix("HRD") }
        if filterText.isEmpty { return scoped }
        return scoped.filter { result in
            displayNameFor(result.checkId).localizedCaseInsensitiveContains(filterText)
                || result.message.localizedCaseInsensitiveContains(filterText)
        }
    }

    private var hrdSummary: LintSummary {
        LintSummary.from(results: hrdResults)
    }

    private var groupedBySeverity: [(label: String, severity: LintSeverity, items: [LintResult])] {
        let errors = hrdResults.filter { $0.severity == .error }
        let warnings = hrdResults.filter { $0.severity == .warning }
        let infos = hrdResults.filter { $0.severity == .info }
        var out: [(label: String, severity: LintSeverity, items: [LintResult])] = []
        if !errors.isEmpty { out.append(("Critical issues", .error, errors)) }
        if !warnings.isEmpty { out.append(("Warnings", .warning, warnings)) }
        if !infos.isEmpty { out.append(("Info", .info, infos)) }
        return out
    }

    var body: some View {
        if isLoading {
            VStack(spacing: 8) {
                Spacer()
                ProgressView().controlSize(.small)
                Text("Scanning...")
                    .font(Typography.body)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                overviewRow
                lintIssuesGroup
            }
            .padding(.vertical, 4)
        }
    }

    private var overviewRow: some View {
        Button {
            selectedLintResultId = nil
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(Typography.body)
                    .frame(width: 16)
                    .foregroundStyle(selectedLintResultId == nil ? .white : .secondary)
                Text("Overview")
                    .font(Typography.body)
                    .foregroundStyle(selectedLintResultId == nil ? .white : .primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(selectedLintResultId == nil ? Color.accentColor : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var lintIssuesGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    lintIssuesExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: lintIssuesExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)
                    Text("Lint Issues")
                        .font(Typography.bodyMedium)
                    Spacer()
                    severityCountsView
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if lintIssuesExpanded {
                if hrdResults.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.green)
                        Text("All hardening checks pass")
                            .font(Typography.body)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
                } else {
                    ForEach(groupedBySeverity, id: \.label) { group in
                        sectionHeader(label: group.label, severity: group.severity)
                        ForEach(group.items) { result in
                            issueRow(result)
                        }
                    }
                }
            }
        }
    }

    private var severityCountsView: some View {
        HStack(spacing: 4) {
            if hrdSummary.errorCount > 0 {
                countPill(count: hrdSummary.errorCount, color: colorForSeverity(.error))
            }
            if hrdSummary.warningCount > 0 {
                countPill(count: hrdSummary.warningCount, color: colorForSeverity(.warning))
            }
            if hrdSummary.infoCount > 0 {
                countPill(count: hrdSummary.infoCount, color: colorForSeverity(.info))
            }
            if hrdResults.isEmpty {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.green)
            }
        }
    }

    private func countPill(count: Int, color: Color) -> some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }

    private func sectionHeader(label: String, severity: LintSeverity) -> some View {
        HStack(spacing: 6) {
            Circle().fill(colorForSeverity(severity)).frame(width: 6, height: 6)
            Text(label.uppercased())
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func issueRow(_ result: LintResult) -> some View {
        HardeningIssueRow(
            result: result,
            isSelected: selectedLintResultId == result.id
        ) {
            if selectedLintResultId == result.id {
                selectedLintResultId = nil
            } else {
                selectedLintResultId = result.id
            }
        }
    }
}

private struct HardeningIssueRow: View {
    let result: LintResult
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Text(result.checkId.rawValue)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isSelected ? .white : colorForSeverity(result.severity))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        isSelected
                            ? AnyShapeStyle(Color.white.opacity(0.18))
                            : AnyShapeStyle(colorForSeverity(result.severity).opacity(0.15))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                Text(displayLabel(for: result))
                    .font(Typography.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isSelected ? .white : .primary)

                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 5)
            .background(
                isSelected
                    ? Color.accentColor
                    : (isHovered ? Color.primary.opacity(0.04) : .clear)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(displayNameFor(result.checkId))
    }
}

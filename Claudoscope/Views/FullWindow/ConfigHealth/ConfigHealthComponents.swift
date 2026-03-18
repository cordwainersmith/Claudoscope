import SwiftUI

// MARK: - Category Section

struct CategorySection: View {
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
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(category.color)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    Text(category.label)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)

                    Text("\(rules.count) \(rules.count == 1 ? "rule" : "rules"), \(totalResults) \(totalResults == 1 ? "item" : "items")")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)

                    Spacer()

                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 11, weight: .medium))
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

struct CategoryIssueRow: View {
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
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)

                        if results.count > 1 {
                            HStack(spacing: 3) {
                                Text(isExpanded ? "Collapse" : "View all")
                                    .font(.system(size: 12))
                                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 11))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(AnyShapeStyle(.quaternary))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            HStack(spacing: 3) {
                                Text("View")
                                    .font(.system(size: 12))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11))
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
                                    .font(.system(size: 12))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Spacer()

                                SessionBadgeView(result: result)

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11))
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

struct RuleGroupRow: View {
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
                        .font(.system(size: 11))
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
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)

                    if results.count > 1 {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11))
                            .foregroundStyle(.quaternary)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11))
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
                                    .font(.system(size: 12))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Spacer()

                                SessionBadgeView(result: result)

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11))
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

struct FileResultRow: View {
    let result: LintResult
    let onSelect: () -> Void

    private var displayName: String {
        result.displayPath ?? (result.filePath as NSString).lastPathComponent
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: severityIcon(result.severity))
                    .font(.system(size: 11))
                    .foregroundStyle(colorForSeverity(result.severity))

                Text(displayNameFor(result.checkId))
                    .font(Typography.body)
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                Spacer()

                SessionBadgeView(result: result)

                Text(displayName)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                if let line = result.line {
                    Text("L\(line)")
                        .font(Typography.codeSmall)
                        .foregroundStyle(.tertiary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
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

// MARK: - Severity Badge

struct SeverityBadge: View {
    let severity: LintSeverity

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: severityIcon(severity))
                .font(.system(size: 11))
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

func colorForSeverity(_ severity: LintSeverity) -> Color {
    switch severity {
    case .error: return Color(red: 0.886, green: 0.294, blue: 0.290)
    case .warning: return Color(red: 0.937, green: 0.624, blue: 0.153)
    case .info: return Color(red: 0.216, green: 0.541, blue: 0.867)
    }
}

func severityIcon(_ severity: LintSeverity) -> String {
    switch severity {
    case .error: return "exclamationmark.triangle.fill"
    case .warning: return "exclamationmark.diamond.fill"
    case .info: return "info.circle.fill"
    }
}

func displayMessage(for result: LintResult) -> String {
    let raw = result.checkId.rawValue
    guard raw.hasPrefix("SES"),
          let tagRange = result.message.range(of: " \\[\\$[^\\]]+\\]$", options: .regularExpression) else {
        return result.message
    }
    return String(result.message[result.message.startIndex..<tagRange.lowerBound])
}

func sessionBadges(for result: LintResult) -> [(text: String, color: Color)] {
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
func SessionBadgeView(result: LintResult) -> some View {
    HStack(spacing: 4) {
        if result.subagentFileName != nil {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9))
                Text("Subagent")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }

        let badges = sessionBadges(for: result)
        ForEach(badges, id: \.text) { badge in
            Text(badge.text)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(badge.color)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(badge.color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }
}

import SwiftUI

/// Cost attribution: which skills, MCP tools and subagent types the money went
/// to, from the tags Claude Code stamps on billed records.
///
/// The presentation rules here are load-bearing, not cosmetic. Only a fraction
/// of billed records carry any tag, and skills and MCP tools are INDEPENDENT
/// partitions over the same spend rather than two slices of one pie. So:
/// every table shows its own unattributed remainder, skills and MCP never share
/// a table or a bar, and nothing is normalized to 100%.
struct AttributionAnalyticsView: View {
    let rollup: AttributionRollup

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if rollup.totalCost <= 0 {
                    EmptyStateView(
                        icon: "tag",
                        title: "No spend in range",
                        message: "Widen the time range to see cost attribution."
                    )
                    .padding(.top, 40)
                } else {
                    coverageCards
                        .padding(.horizontal, 24)

                    if rollup.isEmpty {
                        noAttributionNotice
                            .padding(.horizontal, 24)
                    }

                    AttributionTableView(
                        title: "Cost by Skill",
                        keyColumn: "Skill",
                        rows: rollup.skills.map {
                            AttributionTableRow(
                                id: $0.id,
                                label: $0.skill,
                                badge: $0.isInstalled ? nil : "removed",
                                turns: $0.turnCount,
                                sessions: $0.sessionCount,
                                cost: $0.estimatedCost
                            )
                        },
                        unattributedCost: rollup.skillUnattributedCost,
                        totalCost: rollup.totalCost,
                        emptyMessage: "No skill-tagged turns in range."
                    )
                    .padding(.horizontal, 24)

                    AttributionTableView(
                        title: "Cost by MCP Tool",
                        keyColumn: "Server / Tool",
                        rows: rollup.mcps.map {
                            AttributionTableRow(
                                id: $0.id,
                                label: $0.tool,
                                secondary: $0.server,
                                turns: $0.turnCount,
                                sessions: $0.sessionCount,
                                cost: $0.estimatedCost
                            )
                        },
                        unattributedCost: rollup.mcpUnattributedCost,
                        totalCost: rollup.totalCost,
                        emptyMessage: "No MCP-tagged turns in range."
                    )
                    .padding(.horizontal, 24)

                    agentsTable
                        .padding(.horizontal, 24)

                    footnote
                        .padding(.horizontal, 24)
                }
            }
            .padding(.vertical, 24)
        }
    }

    // MARK: - Coverage

    /// Two coverage figures, never one: the two partitions overlap, so a single
    /// "attributed" number would be meaningless.
    private var coverageCards: some View {
        HStack(spacing: 12) {
            StatCard(
                title: "Skill-attributed",
                value: formatCost(rollup.skillAttributedCost),
                subtitle: percentLabel(rollup.skillCoverage)
            )
            .help("Cost on turns Claude Code tagged with a skill, out of \(formatCost(rollup.totalCost)) total.")
            StatCard(
                title: "MCP-attributed",
                value: formatCost(rollup.mcpAttributedCost),
                subtitle: percentLabel(rollup.mcpCoverage)
            )
            .help("Cost on turns tagged with an MCP tool. Overlaps with skill-attributed cost: a turn can carry both tags.")
            StatCard(
                title: "Subagents",
                value: formatCost(rollup.agents.reduce(0) { $0 + $1.estimatedCost }),
                subtitle: rollup.agents.isEmpty ? nil : "\(rollup.agents.count) types"
            )
            .help("Cost of sessions that ran as a subagent, grouped by agent type.")
        }
    }

    private func percentLabel(_ fraction: Double) -> String {
        String(format: "%.0f%% of total", fraction * 100)
    }

    /// Distinguishes "nothing was tagged" from "nothing was spent". A corpus
    /// written before Claude Code 2.1.24x has real spend and zero attribution,
    /// and showing three empty tables without saying so reads as a bug.
    private var noAttributionNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
            Text("No attribution tags in this range. Claude Code started recording them in 2.1.24x, so older sessions show none even though they cost money.")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AnyShapeStyle(.quaternary))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Agents

    /// No remainder row: unlike skills and MCP tools, this is a partition of
    /// subagent spend only, and main-session cost is not a "remainder" of it.
    private var agentsTable: some View {
        CardView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Cost by Subagent Type")
                    .font(Typography.sectionTitle)

                if rollup.agents.isEmpty {
                    Text("No subagent sessions in range.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                } else {
                    HStack(spacing: 0) {
                        Text("Agent").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Runs").frame(width: 70, alignment: .trailing)
                        Text("Tokens").frame(width: 90, alignment: .trailing)
                        Text("Cost").frame(width: 90, alignment: .trailing)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)

                    ForEach(Array(rollup.agents.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().padding(.horizontal, 12) }
                        HStack(spacing: 0) {
                            Text(row.agent)
                                .font(Typography.bodyMedium)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(row.sessionCount)")
                                .font(Typography.code)
                                .frame(width: 70, alignment: .trailing)
                            Text(formatTokens(row.inputTokens + row.outputTokens))
                                .font(Typography.code)
                                .frame(width: 90, alignment: .trailing)
                            Text(formatCost(row.estimatedCost))
                                .font(Typography.code)
                                .frame(width: 90, alignment: .trailing)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            }
        }
    }

    private var footnote: some View {
        Text("Skill and MCP attribution are measured separately and can overlap: one turn may carry both tags, so the two attributed totals can add up to more than the total cost. Each table's unattributed row is measured against the same total.")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Shared table

struct AttributionTableRow: Identifiable {
    let id: String
    let label: String
    var secondary: String? = nil
    var badge: String? = nil
    let turns: Int
    let sessions: Int
    let cost: Double
}

/// One attribution dimension. Always ends in an Unattributed row so the tagged
/// rows can never be read as the whole of spend.
struct AttributionTableView: View {
    let title: String
    let keyColumn: String
    let rows: [AttributionTableRow]
    let unattributedCost: Double
    let totalCost: Double
    let emptyMessage: String

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(Typography.sectionTitle)
                    Spacer()
                    Text(coverageSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if rows.isEmpty {
                    Text(emptyMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                } else {
                    HStack(spacing: 0) {
                        Text(keyColumn).frame(maxWidth: .infinity, alignment: .leading)
                        Text("Turns").frame(width: 70, alignment: .trailing)
                        Text("Sessions").frame(width: 80, alignment: .trailing)
                        Text("Cost").frame(width: 90, alignment: .trailing)
                        Text("% Total").frame(width: 70, alignment: .trailing)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)

                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().padding(.horizontal, 12) }
                        dataRow(row, colorIndex: index)
                    }

                    Divider().padding(.horizontal, 12)
                    unattributedRow
                }
            }
        }
    }

    private var coverageSummary: String {
        guard totalCost > 0 else { return "" }
        let attributed = totalCost - unattributedCost
        return String(format: "%.0f%% of %@ attributed", attributed / totalCost * 100, formatCost(totalCost))
    }

    private func dataRow(_ row: AttributionTableRow, colorIndex: Int) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.chartCategorical[colorIndex % Color.chartCategorical.count])
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(row.label)
                            .font(Typography.bodyMedium)
                        if let badge = row.badge {
                            Text(badge)
                                .font(.system(size: 10))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.okabeOrange.opacity(0.15))
                                .foregroundStyle(Color.okabeOrange)
                                .clipShape(Capsule())
                        }
                    }
                    if let secondary = row.secondary {
                        Text(secondary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(row.turns)")
                .font(Typography.code)
                .frame(width: 70, alignment: .trailing)
            Text("\(row.sessions)")
                .font(Typography.code)
                .frame(width: 80, alignment: .trailing)
            Text(formatCost(row.cost))
                .font(Typography.code)
                .frame(width: 90, alignment: .trailing)
            Text(percentOfTotal(row.cost))
                .font(Typography.code)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Secondary, never a categorical color: this is the absence of a category,
    /// and giving it a palette slot would read as one more skill or tool.
    private var unattributedRow: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                    .frame(width: 8, height: 8)
                Text("Unattributed")
                    .font(Typography.bodyMedium)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("—")
                .font(Typography.code)
                .foregroundStyle(.tertiary)
                .frame(width: 70, alignment: .trailing)
            Text("—")
                .font(Typography.code)
                .foregroundStyle(.tertiary)
                .frame(width: 80, alignment: .trailing)
            Text(formatCost(unattributedCost))
                .font(Typography.code)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            Text(percentOfTotal(unattributedCost))
                .font(Typography.code)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .help("Cost on turns Claude Code did not tag for this dimension.")
    }

    private func percentOfTotal(_ cost: Double) -> String {
        guard totalCost > 0 else { return "—" }
        return String(format: "%.1f%%", cost / totalCost * 100)
    }
}

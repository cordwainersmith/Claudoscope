import SwiftUI

/// Spend readouts shared by the Skills, Agents and MCPs rails.
///
/// These rails are config surfaces; attribution is overlaid onto them the way
/// the Hooks rail overlays runtime counts. Spend is LIFETIME across the whole
/// corpus, not the Analytics time range, matching the Hooks rail's lifetime
/// fire counts. The windowed view lives in Analytics → Attribution.
///
/// Absence is ambiguous here: a skill with no attributed spend either never ran
/// or only ran before Claude Code 2.1.24x started tagging records. So a zero
/// row shows nothing at all rather than "$0.00", which would assert the first.

/// Trailing chip for a sidebar row. Renders nothing when there is no attributed
/// spend, leaving the row exactly as it was.
struct AttributionSpendChip: View {
    let cost: Double
    var isSelected: Bool = false

    var body: some View {
        if cost > 0 {
            Text(formatCost(cost))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(isSelected ? .white.opacity(0.85) : Color.okabeBlue)
                .help("Estimated lifetime cost attributed to this entry")
        }
    }
}

/// Detail-pane card. Shown only when there is attributed spend; otherwise the
/// caller renders `AttributionNoSpendNote` instead.
struct AttributionSpendCard: View {
    let title: String
    let cost: Double
    let turns: Int
    let sessions: Int
    var tokens: Int? = nil

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 10) {
                ConfigSectionHeader(title: title)
                HStack(alignment: .top, spacing: 24) {
                    stat("Cost", formatCost(cost))
                    if turns > 0 { stat("Turns", "\(turns)") }
                    stat("Sessions", "\(sessions)")
                    if let tokens { stat("Tokens", formatTokens(tokens)) }
                }
                Text("Lifetime estimate from the turns Claude Code attributed here. Not filtered by the Analytics time range.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(Typography.code)
        }
    }
}

/// Explains a missing spend card without claiming the entry was never used.
struct AttributionNoSpendNote: View {
    let noun: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
            Text("No attributed spend for this \(noun). It may not have run, or it ran before Claude Code 2.1.24x began tagging records.")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 2)
    }
}

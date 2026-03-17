import SwiftUI

struct StatsStrip: View {
    let sessionCount: Int
    let tokenCount: Int
    let cost: Double
    let projectCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Today")
                .font(Typography.sectionLabel)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            HStack(spacing: 16) {
                StatItem(label: "Sessions", value: "\(sessionCount)")
                StatItem(label: "Projects", value: "\(projectCount)")
                StatItem(label: "Tokens", value: formatTokens(tokenCount))
                StatItem(label: "Cost", value: formatCost(cost))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct StatItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(Typography.displaySmall)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

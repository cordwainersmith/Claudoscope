import SwiftUI

struct ActiveSessionCard: View {
    let session: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("ACTIVE SESSION")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Spacer()
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
            }

            Text(session.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)

            HStack(spacing: 0) {
                Text(decodeProjectName(session.projectId))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(formatCost(session.estimatedCost))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.orange)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Label("\(session.messageCount)", systemImage: "bubble.left")
                Label(formatTokens(session.totalInputTokens + session.totalOutputTokens), systemImage: "arrow.left.arrow.right")
                Spacer()
                if let model = session.primaryModel {
                    Text(getModelFamily(model).capitalized)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .labelStyle(CompactLabelStyle())
        }
        .padding(12)
        .background(.green.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.green.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

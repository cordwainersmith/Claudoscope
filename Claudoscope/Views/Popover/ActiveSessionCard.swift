import SwiftUI

struct ActiveSessionsCard: View {
    let sessions: [SessionSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(sessions.count == 1 ? "ACTIVE SESSION" : "ACTIVE SESSIONS \u{00B7} \(sessions.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Spacer()
                PulsingDot()
            }
            .padding(.bottom, 8)

            // Session rows
            let sessionRows = ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                if index > 0 {
                    Rectangle()
                        .fill(.green.opacity(0.1))
                        .frame(height: 1)
                        .padding(.vertical, 6)
                }
                ActiveSessionRow(session: session)
            }

            if sessions.count > 4 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        sessionRows
                    }
                }
                .frame(maxHeight: 280)
            } else {
                sessionRows
            }
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

private struct ActiveSessionRow: View {
    let session: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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

                if let model = session.primaryModel {
                    Text(getModelFamily(model).capitalized)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.12))
                        .clipShape(Capsule())
                        .padding(.leading, 6)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Label("\(session.messageCount)", systemImage: "bubble.left")
                Label(formatTokens(session.totalInputTokens + session.totalOutputTokens), systemImage: "arrow.left.arrow.right")
                Spacer()
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .labelStyle(CompactLabelStyle())
        }
    }
}

private struct PulsingDot: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(.green)
            .frame(width: 6, height: 6)
            .opacity(isPulsing ? 0.4 : 1.0)
            .animation(
                .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
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

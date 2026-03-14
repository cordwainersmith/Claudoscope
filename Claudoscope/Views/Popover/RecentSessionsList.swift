import SwiftUI

struct RecentSessionsList: View {
    let sessions: [SessionSummary]
    let onSelect: (SessionSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("RECENT")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .tracking(0.5)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)

            ForEach(sessions) { session in
                Button {
                    onSelect(session)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .foregroundStyle(.primary)

                            Text(decodeProjectName(session.projectId))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(formatRelativeTime(session.lastTimestamp))
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)

                            Text(formatCost(session.estimatedCost))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

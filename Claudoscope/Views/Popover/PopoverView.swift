import SwiftUI

struct PopoverView: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Claudoscope")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Today's stats
            StatsStrip(
                sessionCount: store.todaySessions.count,
                tokenCount: store.todayTokens,
                cost: store.todayCost,
                projectCount: Set(store.todaySessions.map(\.projectId)).count
            )

            // Sparkline
            SparklineChart(dailyUsage: store.analyticsData.dailyUsage)
                .padding(.bottom, 12)

            Divider()

            // Active session (if any)
            if let activeSession = findActiveSession() {
                ActiveSessionCard(session: activeSession)
                    .padding(.vertical, 8)
                Divider()
            }

            // Recent sessions
            if !store.recentSessions.isEmpty {
                RecentSessionsList(sessions: store.recentSessions) { session in
                    openWindow(id: "main")
                }
                .padding(.vertical, 8)
                Divider()
            }

            // Open full view button
            Button {
                openWindow(id: "main")
            } label: {
                HStack {
                    Text("Open full view...")
                        .font(.system(size: 12))
                    Spacer()
                    Text("Cmd+O")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 280)
    }

    private func findActiveSession() -> SessionSummary? {
        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return store.allSessionsWithProjects
            .map(\.session)
            .first { session in
                guard let date = isoFormatter.date(from: session.lastTimestamp) else { return false }
                return now.timeIntervalSince(date) < 60
            }
    }
}

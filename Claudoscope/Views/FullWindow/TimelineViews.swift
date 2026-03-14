import SwiftUI

// MARK: - Timeline Sidebar Content

struct TimelineSidebarContent: View {
    let filterText: String
    let entries: [HistoryEntry]
    var onSelect: ((HistoryEntry) -> Void)?

    private var filteredEntries: [HistoryEntry] {
        if filterText.isEmpty { return entries }
        return entries.filter { entry in
            entry.display.localizedCaseInsensitiveContains(filterText) ||
            (entry.project?.localizedCaseInsensitiveContains(filterText) ?? false) ||
            (entry.sessionId?.localizedCaseInsensitiveContains(filterText) ?? false)
        }
    }

    private var groupedByDay: [(key: String, entries: [HistoryEntry])] {
        let calendar = Calendar.current

        let grouped = Dictionary(grouping: filteredEntries) { entry -> String in
            if calendar.isDateInToday(entry.timestamp) {
                return "Today"
            } else if calendar.isDateInYesterday(entry.timestamp) {
                return "Yesterday"
            } else {
                let formatter = DateFormatter()
                formatter.dateFormat = "EEE, MMM d"
                return formatter.string(from: entry.timestamp)
            }
        }

        // Sort groups by the newest entry in each group
        return grouped
            .map { (key: $0.key, entries: $0.value.sorted { $0.timestamp > $1.timestamp }) }
            .sorted { groupA, groupB in
                let dateA = groupA.entries.first?.timestamp ?? .distantPast
                let dateB = groupB.entries.first?.timestamp ?? .distantPast
                return dateA > dateB
            }
    }

    var body: some View {
        if filteredEntries.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.system(size: 24))
                    .foregroundStyle(.quaternary)
                Text("No history found")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(groupedByDay, id: \.key) { group in
                    daySection(group.key, entries: group.entries)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func daySection(_ dayLabel: String, entries: [HistoryEntry]) -> some View {
        HStack(spacing: 6) {
            Text(dayLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Text("\(entries.count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(AnyShapeStyle(.quaternary))
                .clipShape(Capsule())

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)

        ForEach(entries) { entry in
            TimelineSidebarRow(entry: entry) {
                onSelect?(entry)
            }
        }
    }
}

// MARK: - Timeline Sidebar Row

private struct TimelineSidebarRow: View {
    let entry: HistoryEntry
    let onSelect: () -> Void

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: entry.timestamp)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 6) {
                Text(timeString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 36, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.display)
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .foregroundStyle(.primary)

                    if let label = projectLabel(entry.project) {
                        Text(label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(AnyShapeStyle(.quaternary))
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Timeline Main Panel View

struct TimelineMainPanelView: View {
    let entries: [HistoryEntry]
    let isLoading: Bool

    private static let projectColors: [Color] = [
        .blue.opacity(0.7),
        .green.opacity(0.7),
        .orange.opacity(0.7),
        .pink.opacity(0.7),
        .indigo.opacity(0.7),
        .yellow.opacity(0.7)
    ]

    private var groupedByDay: [(key: String, entries: [HistoryEntry])] {
        let calendar = Calendar.current

        let grouped = Dictionary(grouping: entries) { entry -> String in
            if calendar.isDateInToday(entry.timestamp) {
                return "Today"
            } else if calendar.isDateInYesterday(entry.timestamp) {
                return "Yesterday"
            } else {
                let formatter = DateFormatter()
                formatter.dateFormat = "EEE, MMM d"
                return formatter.string(from: entry.timestamp)
            }
        }

        return grouped
            .map { (key: $0.key, entries: $0.value.sorted { $0.timestamp > $1.timestamp }) }
            .sorted { groupA, groupB in
                let dateA = groupA.entries.first?.timestamp ?? .distantPast
                let dateB = groupB.entries.first?.timestamp ?? .distantPast
                return dateA > dateB
            }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                EmptyStateView(
                    icon: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                    title: "No timeline entries",
                    message: "History entries from your Claude Code sessions will appear here."
                )
            } else {
                timelineContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var timelineContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groupedByDay, id: \.key) { group in
                    dayHeader(group.key, count: group.entries.count)

                    ForEach(group.entries) { entry in
                        timelineRow(entry)
                    }
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 24)
        }
    }

    @ViewBuilder
    private func dayHeader(_ label: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)

            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(AnyShapeStyle(.quaternary))
                .clipShape(Capsule())

            Spacer()
        }
        .padding(.leading, 24)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func timelineRow(_ entry: HistoryEntry) -> some View {
        let dotColor = colorForProject(entry.project)

        HStack(alignment: .top, spacing: 0) {
            // Spine with dot
            ZStack {
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 1)

                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
            }
            .frame(width: 16)

            // Entry content
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(formatTime(entry.timestamp))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)

                    Text(formatRelativeTime(entry.timestamp))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                Text(entry.display)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)

                if let label = projectLabel(entry.project) {
                    Text(label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(dotColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(dotColor.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            .padding(.leading, 10)
            .padding(.vertical, 8)
        }
    }

    private func colorForProject(_ path: String?) -> Color {
        guard let path else { return Self.projectColors[0] }
        let hash = abs(path.hashValue)
        let index = hash % Self.projectColors.count
        return Self.projectColors[index]
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func formatRelativeTime(_ date: Date) -> String {
        let now = Date()
        let interval = now.timeIntervalSince(date)

        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else if interval < 604800 {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .none
            return formatter.string(from: date)
        }
    }
}

// MARK: - Helpers

private func projectLabel(_ path: String?) -> String? {
    guard let path else { return nil }
    return path.split(separator: "/").last.map(String.init)
}

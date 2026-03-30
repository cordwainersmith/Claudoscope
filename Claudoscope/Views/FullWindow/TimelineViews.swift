import SwiftUI

// MARK: - Timeline Sidebar Content

struct TimelineSidebarContent: View {
    let filterText: String
    let entries: [HistoryEntry]
    @Binding var selectedDay: String?
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
                    .font(Typography.body)
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
        Button {
            selectedDay = (selectedDay == dayLabel) ? nil : dayLabel
        } label: {
            HStack(spacing: 6) {
                Text(dayLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selectedDay == dayLabel ? .white : .secondary)

                Text("\(entries.count)")
                    .font(Typography.caption)
                    .foregroundStyle(selectedDay == dayLabel ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(selectedDay == dayLabel ? AnyShapeStyle(.white.opacity(0.2)) : AnyShapeStyle(.quaternary))
                    .clipShape(Capsule())

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .background(selectedDay == dayLabel ? Color.accentColor : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

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
                    .font(Typography.code)
                    .foregroundStyle(.tertiary)
                    .frame(width: 36, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.display)
                        .font(Typography.body)
                        .lineLimit(2)
                        .foregroundStyle(.primary)

                    if let label = projectLabel(entry.project) {
                        Text(label)
                            .font(Typography.caption)
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
    var onNavigateToSession: ((String, String, String?) -> Void)?

    @Environment(SessionStore.self) private var store
    @State private var expandedEntries: Set<String> = []

    private static let projectColors: [Color] = [
        .blue, .green, .orange, .pink, .indigo, .yellow
    ]

    private static let timeGutterWidth: CGFloat = 44
    private static let stripWidth: CGFloat = 3
    private static let longMessageThreshold = 120

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private var groupedByDay: [(key: String, entries: [HistoryEntry])] {
        let calendar = Calendar.current

        let grouped = Dictionary(grouping: entries) { entry -> String in
            if calendar.isDateInToday(entry.timestamp) {
                return "Today"
            } else if calendar.isDateInYesterday(entry.timestamp) {
                return "Yesterday"
            } else {
                return Self.dayFormatter.string(from: entry.timestamp)
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

                    ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                        let prev = index > 0 ? group.entries[index - 1] : nil
                        let gap = timeGapCategory(from: prev, to: entry)

                        if gap == .large && index > 0 {
                            gapSeparator
                        }

                        timelineRow(
                            entry: entry,
                            previousEntry: prev,
                            gap: gap
                        )
                    }
                }
            }
            .padding(.vertical, Spacing.lg)
            .padding(.horizontal, Spacing.xl)
        }
    }

    // MARK: - Day Header

    @ViewBuilder
    private func dayHeader(_ label: String, count: Int) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(label)
                .font(Typography.sectionTitle)
                .foregroundStyle(.primary)

            Text("\(count)")
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(AnyShapeStyle(.quaternary))
                .clipShape(Capsule())

            Spacer()
        }
        .padding(.leading, Self.timeGutterWidth + Spacing.md + Self.stripWidth + Spacing.sm)
        .padding(.top, Spacing.lg)
        .padding(.bottom, Spacing.sm)
    }

    // MARK: - Timeline Row

    @ViewBuilder
    private func timelineRow(entry: HistoryEntry, previousEntry: HistoryEntry?, gap: TimeGap) -> some View {
        let projectColor = colorForProject(entry.project)
        let isCommand = entry.display.hasPrefix("/")
        let isLong = !isCommand && entry.display.count > Self.longMessageThreshold
        let isExpanded = expandedEntries.contains(entry.id)
        let showBadge = shouldShowProjectBadge(entry, previousEntry: previousEntry, gap: gap)
        let showSession = shouldShowSessionId(entry, previousEntry: previousEntry)

        HStack(alignment: .top, spacing: 0) {
            // Time gutter
            VStack(alignment: .trailing, spacing: 1) {
                if !Calendar.current.isDateInToday(entry.timestamp) {
                    Text(Self.shortDateFormatter.string(from: entry.timestamp))
                        .font(Typography.micro)
                        .foregroundStyle(.quaternary)
                }
                Text(smartTimeString(entry.timestamp))
                    .font(Typography.codeSmall)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: Self.timeGutterWidth, alignment: .trailing)

            // Project color strip
            Rectangle()
                .fill(projectColor)
                .frame(width: Self.stripWidth)
                .padding(.leading, Spacing.md)

            // Content
            VStack(alignment: .leading, spacing: Spacing.xs) {
                // Session name (shown when session changes)
                if showSession, let info = sessionInfo(for: entry.sessionId) {
                    HStack {
                        Spacer()
                        if onNavigateToSession != nil {
                            Button {
                                onNavigateToSession?(info.projectId, info.sessionId, nil)
                            } label: {
                                HStack(spacing: 3) {
                                    Text(info.title)
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 8, weight: .semibold))
                                }
                                .font(Typography.codeSmall)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.08))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(info.title)
                                .font(Typography.codeSmall)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.08))
                                .clipShape(Capsule())
                        }
                    }
                }

                if isCommand {
                    Text(entry.display)
                        .font(Typography.codeSmall)
                        .foregroundStyle(.tertiary)
                } else if isLong && !isExpanded {
                    Text(entry.display)
                        .font(Typography.body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .textSelection(.enabled)

                    Button {
                        withAnimation(.easeOut(duration: Motion.quick)) {
                            _ = expandedEntries.insert(entry.id)
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                            Text("Show more")
                        }
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(entry.display)
                        .font(Typography.body)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)

                    if isLong {
                        Button {
                            withAnimation(.easeOut(duration: Motion.quick)) {
                                _ = expandedEntries.remove(entry.id)
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 8, weight: .semibold))
                                Text("Show less")
                            }
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if showBadge, let label = projectLabel(entry.project) {
                    Text(label)
                        .font(Typography.caption)
                        .foregroundStyle(projectColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(projectColor.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            .padding(.leading, Spacing.sm)
            .padding(.vertical, isCommand ? Spacing.xs : Spacing.sm)
        }
        .padding(.top, gap.spacing)
    }

    // MARK: - Gap Separator

    private var gapSeparator: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.08))
            .frame(height: 1)
            .padding(.leading, Self.timeGutterWidth + Spacing.md)
            .padding(.vertical, Spacing.sm)
    }

    // MARK: - Time Gap

    private enum TimeGap: Equatable {
        case tight
        case normal
        case wide
        case large

        var spacing: CGFloat {
            switch self {
            case .tight: return 0
            case .normal: return Spacing.xs
            case .wide: return Spacing.md
            case .large: return Spacing.lg
            }
        }
    }

    private func timeGapCategory(from previous: HistoryEntry?, to current: HistoryEntry) -> TimeGap {
        guard let previous else { return .tight }
        let interval = abs(previous.timestamp.timeIntervalSince(current.timestamp))
        if interval < 120 { return .tight }
        if interval < 600 { return .normal }
        if interval < 1800 { return .wide }
        return .large
    }

    // MARK: - Helpers

    private func shouldShowProjectBadge(_ entry: HistoryEntry, previousEntry: HistoryEntry?, gap: TimeGap) -> Bool {
        guard let prev = previousEntry else { return true }
        if gap == .large { return true }
        return entry.project != prev.project
    }

    private func shouldShowSessionId(_ entry: HistoryEntry, previousEntry: HistoryEntry?) -> Bool {
        guard let sid = entry.sessionId else { return false }
        guard let prev = previousEntry else { return true }
        return prev.sessionId != sid
    }

    private func sessionInfo(for sessionId: String?) -> (title: String, projectId: String, sessionId: String)? {
        guard let sessionId else { return nil }
        for (projectId, sessions) in store.sessionsByProject {
            if let match = sessions.first(where: { $0.id == sessionId }) {
                return (match.title, projectId, sessionId)
            }
        }
        return nil
    }

    private func smartTimeString(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "now"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m"
        }
        return Self.timeFormatter.string(from: date)
    }

    private func colorForProject(_ path: String?) -> Color {
        guard let path else { return Self.projectColors[0] }
        let hash = abs(path.hashValue)
        let index = hash % Self.projectColors.count
        return Self.projectColors[index]
    }
}

// MARK: - Helpers

private func projectLabel(_ path: String?) -> String? {
    guard let path else { return nil }
    return path.split(separator: "/").last.map(String.init)
}

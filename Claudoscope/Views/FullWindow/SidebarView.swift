import SwiftUI

struct SidebarView: View {
    let rail: RailItem
    let width: CGFloat
    @Environment(SessionStore.self) private var store
    @Binding var selectedProjectId: String?
    @Binding var selectedSessionId: String?
    @Binding var selectedPlanFilename: String?
    @Binding var selectedHookEventId: String?
    @Binding var selectedCommandName: String?
    @Binding var selectedSkillName: String?
    @Binding var selectedAgentName: String?
    @Binding var selectedMcpName: String?
    @Binding var selectedMemoryId: String?
    @Binding var selectedMemoryProjectId: String?
    @Binding var selectedCanonProjectId: String?
    @Binding var selectedSettingsSection: String?
    @Binding var selectedLintResultId: String?
    @Binding var hiddenLintSeverities: Set<LintSeverity>
    @Binding var selectedHealthItem: String?
    @Binding var selectedTimelineDay: String?
    @Binding var selectedCoworkSessionId: String?
    @Binding var selectedPluginId: String?
    @Binding var selectedTasksJobsItem: TasksJobsSelection?
    @Binding var selectedInsightSessionId: String?
    let analyticsTab: AnalyticsTab
    @Binding var healthSection: HealthSection
    @State private var filterText = ""

    private var showsGlobalFilter: Bool {
        switch rail {
        case .sessions, .tools, .timeline, .plans: return true
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsGlobalFilter {
                GlobalFilterBar(store: store)
                Divider()
            }

            // Filter field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                TextField("Filter \(rail.label.lowercased())...", text: $filterText)
                    .textFieldStyle(.plain)
                    .font(Typography.body)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            // Content based on rail
            ScrollView {
                switch rail {
                // The minute clock drives the rows' relative times: rows only
                // re-render when their own model changes, so without it a
                // quiet session's "3m ago" would never tick.
                case .sessions:
                    TimelineView(.everyMinute) { context in
                        SessionsSidebarContent(
                            projects: store.filteredProjects,
                            rowsByProject: store.filteredSessionsByProject.mapValues(SessionRowModel.rows),
                            now: context.date,
                            filterText: filterText,
                            globalFilterActive: store.globalFilterActive,
                            bookmarks: store.bookmarks,
                            bookmarkCounts: store.bookmarkCountsBySession,
                            knownSessionIds: Set(store.sessionsByProject.values.joined().map(\.id)),
                            onOpenBookmark: { store.openBookmark($0) },
                            selectedSessionId: $selectedSessionId,
                            selectedProjectId: $selectedProjectId
                        )
                    }
                case .tools:
                    TimelineView(.everyMinute) { context in
                        ToolsSidebarContent(
                            projects: store.filteredProjects,
                            rowsByProject: store.filteredSessionsByProject.mapValues(SessionRowModel.rows),
                            now: context.date,
                            filterText: filterText,
                            globalFilterActive: store.globalFilterActive,
                            selectedSessionId: $selectedSessionId,
                            selectedProjectId: $selectedProjectId
                        )
                    }
                case .analytics:
                    switch analyticsTab {
                    case .usage:
                        AnalyticsSidebarContent(
                            projectCosts: store.analyticsData.projectCosts,
                            totalCost: store.analyticsData.totalCost,
                            filterText: filterText,
                            timeRangeLabel: store.analyticsTimeRange.rawValue,
                            selectedProjectId: Binding(
                                get: { store.selectedAnalyticsProjectId },
                                set: { newValue in
                                    store.selectedAnalyticsProjectId = newValue
                                    store.recomputeAnalytics()
                                }
                            )
                        )
                    case .insights:
                        InsightsSidebarContent(
                            filterText: filterText,
                            data: store.insightsData,
                            selectedSessionId: $selectedInsightSessionId
                        )
                    }
                case .plans:
                    PlansSidebarContent(
                        filterText: filterText,
                        plans: store.filteredPlans,
                        globalFilterActive: store.globalFilterActive,
                        selectedPlanFilename: $selectedPlanFilename
                    )
                case .timeline:
                    TimelineSidebarContent(
                        filterText: filterText,
                        entries: store.filteredTimelineEntries,
                        globalFilterActive: store.globalFilterActive,
                        selectedDay: $selectedTimelineDay
                    )
                case .fleet:
                    // Fleet is a full-width board with no sidebar.
                    EmptyView()
                case .tasksJobs:
                    TasksJobsSidebarContent(
                        filterText: filterText,
                        jobs: store.jobs,
                        taskLists: store.taskLists,
                        daemonStatus: store.daemonStatus,
                        selection: $selectedTasksJobsItem
                    )
                case .cowork:
                    CoworkSidebarContent(
                        filterText: filterText,
                        sessions: store.coworkSessions,
                        parsedSessionsByID: store.coworkParsedSessionsByID,
                        pricingTable: store.pricingTable,
                        selectedSessionId: $selectedCoworkSessionId
                    )
                case .hooks:
                    HooksSidebarContent(
                        filterText: filterText,
                        hookGroups: store.hookGroups,
                        runtimeAggregates: store.hookRuntimeAggregates,
                        selectedEventId: $selectedHookEventId
                    )
                case .commands:
                    CommandsSidebarContent(
                        filterText: filterText,
                        commands: store.commands,
                        selectedCommandName: $selectedCommandName
                    )
                case .skills:
                    SkillsSidebarContent(
                        filterText: filterText,
                        skills: store.skills,
                        selectedSkillName: $selectedSkillName,
                        attribution: store.attributionRollup.skills
                    )
                case .agents:
                    AgentsSidebarContent(
                        filterText: filterText,
                        agents: store.agents,
                        selectedAgentName: $selectedAgentName,
                        attribution: store.attributionRollup.agents
                    )
                case .plugins:
                    PluginsSidebarContent(
                        filterText: filterText,
                        plugins: store.plugins,
                        selectedPluginId: $selectedPluginId
                    )
                case .mcps:
                    McpsSidebarContent(
                        filterText: filterText,
                        mcpServers: store.mcpServers,
                        selectedMcpName: $selectedMcpName,
                        attribution: store.attributionRollup.mcps
                    )
                case .memory:
                    MemorySidebarContent(
                        filterText: filterText,
                        projects: store.projects,
                        memoryFiles: store.memoryFiles,
                        selectedMemoryId: $selectedMemoryId,
                        selectedProjectId: $selectedMemoryProjectId
                    )
                case .canon:
                    CanonSidebarContent(
                        filterText: filterText,
                        projects: store.canonRailProjects,
                        detectedProjectIds: store.canonDetectedProjectIds,
                        selectedProjectId: $selectedCanonProjectId
                    )
                case .configHealth:
                    VStack(spacing: 0) {
                        Picker("", selection: $healthSection) {
                            ForEach(HealthSection.allCases, id: \.self) { section in
                                Text(section.rawValue).tag(section)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)

                        switch healthSection {
                        case .health:
                            ConfigHealthSidebarContent(
                                filterText: filterText,
                                lintResults: store.lintResults,
                                lintSummary: store.lintSummary,
                                isLoading: store.lintLoading,
                                selectedItem: $selectedHealthItem,
                                hiddenSeverities: $hiddenLintSeverities
                            )
                        case .hardening:
                            HardeningSidebarContent(
                                filterText: filterText,
                                lintResults: store.lintResults,
                                isLoading: store.lintLoading,
                                selectedLintResultId: $selectedLintResultId
                            )
                        case .routing:
                            RoutingSidebarContent(
                                filterText: filterText,
                                lintResults: store.lintResults,
                                isLoading: store.lintLoading,
                                selectedLintResultId: $selectedLintResultId
                            )
                        }
                    }
                case .settings:
                    SettingsSidebarContent(
                        filterText: filterText,
                        selectedSection: $selectedSettingsSection
                    )
                }
            }
        }
        .onChange(of: rail) { _, _ in filterText = "" }
        .frame(width: width)
        .background(.bar.opacity(0.5))
    }
}

// MARK: - Global Filter Bar

/// Persistent project + date lens shown above the per-rail text filter on the
/// sessions/tools/timeline/plans rails. Backed by `SessionStore`'s
/// `globalFilter*` state so the scope survives switching between those rails,
/// unlike the text filter which resets per rail.
private struct GlobalFilterBar: View {
    let store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Menu {
                    Button("All projects") { store.globalFilterProjectId = nil }
                    if !store.projects.isEmpty {
                        Divider()
                        ForEach(store.projects) { project in
                            Button(project.name) { store.globalFilterProjectId = project.id }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 10))
                        Text(selectedProjectLabel)
                            .lineLimit(1)
                    }
                    .font(Typography.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Menu {
                    ForEach(AnalyticsTimeRange.allCases, id: \.self) { range in
                        Button(range.rawValue.capitalized) { store.globalFilterRange = range }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.system(size: 10))
                        Text(store.globalFilterRange.rawValue.capitalized)
                            .lineLimit(1)
                    }
                    .font(Typography.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                if store.globalFilterActive {
                    Button {
                        store.globalFilterProjectId = nil
                        store.globalFilterRange = .all
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear filter")
                }
            }

            if store.globalFilterRange == .custom {
                HStack(spacing: 8) {
                    DatePicker("", selection: Binding(
                        get: { store.globalFilterCustomFrom },
                        set: { store.globalFilterCustomFrom = $0 }
                    ), displayedComponents: .date)
                        .labelsHidden()
                    Text("to")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                    DatePicker("", selection: Binding(
                        get: { store.globalFilterCustomTo },
                        set: { store.globalFilterCustomTo = $0 }
                    ), displayedComponents: .date)
                        .labelsHidden()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var selectedProjectLabel: String {
        guard let id = store.globalFilterProjectId else { return "All projects" }
        return store.projects.first(where: { $0.id == id })?.name ?? "All projects"
    }
}

/// Shown in a rail's sidebar when the global project/date filter has narrowed
/// the list down to nothing. Not `private` so the other rail files can reuse it.
struct GlobalFilterEmptyRow: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text("No results for this filter")
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

// MARK: - Sessions Sidebar

private struct SessionsSidebarContent: View {
    let projects: [Project]
    let rowsByProject: [String: [SessionRowModel]]
    let now: Date
    let filterText: String
    let globalFilterActive: Bool
    let bookmarks: [Bookmark]
    let bookmarkCounts: [String: Int]
    let knownSessionIds: Set<String>
    let onOpenBookmark: (Bookmark) -> Void
    @Binding var selectedSessionId: String?
    @Binding var selectedProjectId: String?
    @State private var collapsedProjectIds: Set<String> = []

    var filteredProjects: [Project] {
        if filterText.isEmpty { return projects }
        return projects.filter { project in
            project.name.localizedCaseInsensitiveContains(filterText) ||
            visibleSessions(for: project).contains { session in
                session.title.localizedCaseInsensitiveContains(filterText)
            }
        }
    }

    /// The sidebar filter field applies to bookmarks too (title, excerpt, note).
    private var filteredBookmarks: [Bookmark] {
        if filterText.isEmpty { return bookmarks }
        return bookmarks.filter {
            $0.sessionTitle.localizedCaseInsensitiveContains(filterText)
                || $0.excerpt.localizedCaseInsensitiveContains(filterText)
                || $0.note.localizedCaseInsensitiveContains(filterText)
        }
    }

    var body: some View {
        if globalFilterActive && filteredProjects.isEmpty && filteredBookmarks.isEmpty {
            GlobalFilterEmptyRow()
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !filteredBookmarks.isEmpty {
                    BookmarksSidebarSection(
                        bookmarks: filteredBookmarks,
                        knownSessionIds: knownSessionIds,
                        onOpen: onOpenBookmark
                    )
                }
                ForEach(filteredProjects) { project in
                    let sessions = filteredSessions(for: project)
                    let isExpanded = !collapsedProjectIds.contains(project.id)
                    Section {
                        if isExpanded {
                            ForEach(sessions) { session in
                                SessionRow(
                                    session: session,
                                    now: now,
                                    bookmarkCount: bookmarkCounts[session.id] ?? 0,
                                    isSelected: selectedSessionId == session.id
                                ) {
                                    selectedSessionId = session.id
                                    selectedProjectId = project.id
                                }
                            }
                        }
                    } header: {
                        ProjectSectionHeader(project: project, count: sessions.count, isExpanded: isExpanded) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if isExpanded {
                                    collapsedProjectIds.insert(project.id)
                                } else {
                                    collapsedProjectIds.remove(project.id)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func visibleSessions(for project: Project) -> [SessionRowModel] {
        rowsByProject[project.id] ?? []
    }

    private func filteredSessions(for project: Project) -> [SessionRowModel] {
        let sessions = visibleSessions(for: project)
        if filterText.isEmpty { return sessions }
        return sessions.filter { $0.title.localizedCaseInsensitiveContains(filterText) }
    }
}

private struct SessionRow: View {
    let session: SessionRowModel
    let now: Date
    var bookmarkCount: Int = 0
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(Typography.body)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .white : .primary)

                HStack(spacing: 4) {
                    Text(session.lastDate.map { formatRelativeTime($0, now: now) } ?? "")
                        .font(.system(size: 11))

                    Text("\u{00B7}")
                        .font(.system(size: 11))

                    Text("\(session.messageCount) msgs")
                        .font(.system(size: 11))

                    if !session.errorLabels.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.red)
                            .help("Errors: \(session.errorLabels.joined(separator: ", "))")
                    }

                    if session.hasIdleZombieGap {
                        Image(systemName: "moon.zzz.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .help("Session resumed after 75+ min idle without /clear")
                    }

                    if session.isWorktree {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9))
                            .foregroundStyle(.cyan)
                            .help(session.worktreeHelp)
                    }

                    if let prNumber = session.prNumber {
                        Text("#\(prNumber)")
                            .font(.system(size: 9))
                            .foregroundStyle(.cyan)
                            .help(session.prUrl ?? "Pull request #\(prNumber)")
                    }

                    if bookmarkCount > 0 {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.okabeOrange)
                            .help("\(bookmarkCount) bookmarked turn\(bookmarkCount == 1 ? "" : "s")")
                    }

                    if let family = session.modelFamily {
                        Spacer()
                        Text(family)
                            .font(Typography.micro)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(isSelected ? AnyShapeStyle(.white.opacity(0.2)) : AnyShapeStyle(.quaternary))
                            .clipShape(Capsule())
                    }
                }
                .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.leading, 18)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor : (isHovered ? Color.primary.opacity(0.04) : .clear))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Analytics Sidebar

private struct AnalyticsSidebarContent: View {
    let projectCosts: [ProjectCost]
    let totalCost: Double
    let filterText: String
    let timeRangeLabel: String
    @Binding var selectedProjectId: String?

    var filtered: [ProjectCost] {
        if filterText.isEmpty { return projectCosts }
        return projectCosts.filter { $0.projectName.localizedCaseInsensitiveContains(filterText) }
    }

    var maxCost: Double {
        filtered.map(\.totalCost).max() ?? 1
    }

    private let barColors = Color.chartCategorical

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            // Section header
            Text("COST BY PROJECT (\(timeRangeLabel.uppercased()))")
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)

            // "All projects" row
            AnalyticsProjectRow(
                name: "All projects",
                cost: totalCost,
                barWidth: 1.0,
                barColor: .accentColor,
                isSelected: selectedProjectId == nil
            ) {
                selectedProjectId = nil
            }

            // Per-project rows
            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, cost in
                AnalyticsProjectRow(
                    name: cost.projectName,
                    cost: cost.totalCost,
                    barWidth: cost.totalCost / maxCost,
                    barColor: barColors[index % barColors.count],
                    isSelected: selectedProjectId == cost.projectId
                ) {
                    selectedProjectId = cost.projectId
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct AnalyticsProjectRow: View {
    let name: String
    let cost: Double
    let barWidth: Double
    let barColor: Color
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name)
                        .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)
                        .lineLimit(1)
                        .help(name)
                    Spacer()
                    Text(formatCost(cost))
                        .font(Typography.code)
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                }

                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor.opacity(0.6))
                        .frame(width: max(4, geo.size.width * barWidth))
                }
                .frame(height: 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.08) : (isHovered ? Color.primary.opacity(0.04) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

import SwiftUI

struct SidebarView: View {
    let rail: RailItem
    @Environment(SessionStore.self) private var store
    @Binding var selectedProjectId: String?
    @Binding var selectedSessionId: String?
    @Binding var selectedPlanFilename: String?
    @Binding var selectedHookEventId: String?
    @Binding var selectedCommandName: String?
    @Binding var selectedSkillName: String?
    @Binding var selectedMcpName: String?
    @Binding var selectedMemoryId: String?
    @Binding var selectedSettingsSection: String?
    @State private var filterText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Filter field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("Filter...", text: $filterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            // Content based on rail
            ScrollView {
                switch rail {
                case .sessions:
                    SessionsSidebarContent(
                        projects: store.projects,
                        sessionsByProject: store.sessionsByProject,
                        filterText: filterText,
                        selectedSessionId: $selectedSessionId,
                        selectedProjectId: $selectedProjectId
                    )
                case .analytics:
                    AnalyticsSidebarContent(
                        projectCosts: store.sidebarAnalyticsData.projectCosts,
                        totalCost: store.sidebarAnalyticsData.totalCost,
                        filterText: filterText,
                        selectedProjectId: Binding(
                            get: { store.selectedAnalyticsProjectId },
                            set: { newValue in
                                store.selectedAnalyticsProjectId = newValue
                                store.recomputeAnalytics()
                            }
                        )
                    )
                case .plans:
                    PlansSidebarContent(
                        filterText: filterText,
                        plans: store.plans,
                        selectedPlanFilename: $selectedPlanFilename
                    )
                case .timeline:
                    TimelineSidebarContent(
                        filterText: filterText,
                        entries: store.timelineEntries
                    )
                case .hooks:
                    HooksSidebarContent(
                        filterText: filterText,
                        hookGroups: store.hookGroups,
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
                        selectedSkillName: $selectedSkillName
                    )
                case .mcps:
                    McpsSidebarContent(
                        filterText: filterText,
                        mcpServers: store.mcpServers,
                        selectedMcpName: $selectedMcpName
                    )
                case .memory:
                    MemorySidebarContent(
                        filterText: filterText,
                        memoryFiles: store.memoryFiles,
                        selectedMemoryId: $selectedMemoryId
                    )
                case .settings:
                    SettingsSidebarContent(
                        filterText: filterText,
                        selectedSection: $selectedSettingsSection
                    )
                }
            }
        }
        .frame(width: 240)
        .background(.bar.opacity(0.5))
    }
}

// MARK: - Sessions Sidebar

private struct SessionsSidebarContent: View {
    let projects: [Project]
    let sessionsByProject: [String: [SessionSummary]]
    let filterText: String
    @Binding var selectedSessionId: String?
    @Binding var selectedProjectId: String?

    var filteredProjects: [Project] {
        if filterText.isEmpty { return projects }
        return projects.filter { project in
            project.name.localizedCaseInsensitiveContains(filterText) ||
            (sessionsByProject[project.id] ?? []).contains { session in
                session.title.localizedCaseInsensitiveContains(filterText)
            }
        }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(filteredProjects) { project in
                ProjectGroup(
                    project: project,
                    sessions: filteredSessions(for: project),
                    selectedSessionId: $selectedSessionId,
                    selectedProjectId: $selectedProjectId
                )
            }
        }
        .padding(.vertical, 4)
    }

    private func filteredSessions(for project: Project) -> [SessionSummary] {
        let sessions = sessionsByProject[project.id] ?? []
        if filterText.isEmpty { return sessions }
        return sessions.filter { $0.title.localizedCaseInsensitiveContains(filterText) }
    }
}

private struct ProjectGroup: View {
    let project: Project
    let sessions: [SessionSummary]
    @Binding var selectedSessionId: String?
    @Binding var selectedProjectId: String?
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Project header
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)

                    Text(project.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)

                    Spacer()

                    Text("\(sessions.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(sessions) { session in
                    SessionRow(
                        session: session,
                        isSelected: selectedSessionId == session.id
                    ) {
                        selectedSessionId = session.id
                        selectedProjectId = project.id
                    }
                }
            }
        }
    }
}

private struct SessionRow: View {
    let session: SessionSummary
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .white : .primary)

                HStack(spacing: 4) {
                    Text(formatRelativeTime(session.lastTimestamp))
                        .font(.system(size: 10))

                    Text(".")
                        .font(.system(size: 10))

                    Text("\(session.messageCount) msgs")
                        .font(.system(size: 10))

                    if let model = session.primaryModel {
                        let family = getModelFamily(model)
                        Spacer()
                        Text(family)
                            .font(.system(size: 9, weight: .medium))
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
            .background(isSelected ? Color.accentColor : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Analytics Sidebar

private struct AnalyticsSidebarContent: View {
    let projectCosts: [ProjectCost]
    let totalCost: Double
    let filterText: String
    @Binding var selectedProjectId: String?

    var filtered: [ProjectCost] {
        if filterText.isEmpty { return projectCosts }
        return projectCosts.filter { $0.projectName.localizedCaseInsensitiveContains(filterText) }
    }

    var maxCost: Double {
        filtered.map(\.totalCost).max() ?? 1
    }

    private let barColors: [Color] = [
        .blue, .green, .orange, .red, .purple, .cyan, .yellow, .pink, .mint, .teal
    ]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            // Section header
            Text("COST BY PROJECT (30D)")
                .font(.system(size: 10, weight: .medium))
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

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name)
                        .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)
                        .lineLimit(1)
                    Spacer()
                    Text(formatCost(cost))
                        .font(.system(size: 11, design: .monospaced))
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
            .background(isSelected ? Color.accentColor.opacity(0.08) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

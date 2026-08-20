import SwiftUI
import Charts

struct MainPanelView: View {
    let rail: RailItem
    @Environment(SessionStore.self) private var store

    // Plans
    @Binding var selectedPlanFilename: String?

    // Config
    let selectedHookEventId: String?
    @Binding var selectedCommandName: String?
    @Binding var selectedSkillName: String?
    @Binding var selectedAgentName: String?
    let selectedMcpName: String?
    @Binding var selectedMemoryId: String?
    let selectedCanonProjectId: String?

    // Config Health
    @Binding var selectedLintResultId: String?
    @Binding var hiddenLintSeverities: Set<LintSeverity>
    let selectedHealthItem: String?
    let selectedProjectId: String?

    // Settings
    @Binding var selectedSettingsSection: String?

    // Cowork
    @Binding var selectedCoworkSessionId: String?

    // Plugins
    @Binding var selectedPluginId: String?

    // Tasks & Jobs
    var selectedTasksJobsItem: TasksJobsSelection?

    // Insights (a tab inside the Analytics rail)
    var selectedInsightSessionId: String?
    @Binding var analyticsTab: AnalyticsTab

    // Merged Health rail section
    var healthSection: HealthSection = .health

    // Session navigation from config health (projectId, sessionId, subagentFileName?)
    var onNavigateToSession: ((String, String, String?) -> Void)?

    var body: some View {
        Group {
            switch rail {
            case .analytics:
                VStack(spacing: 0) {
                    Picker("", selection: $analyticsTab) {
                        ForEach(AnalyticsTab.allCases, id: \.self) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 240)
                    .padding(.vertical, 8)

                    Divider()

                    switch analyticsTab {
                    case .usage:
                        AnalyticsDetailView()
                    case .insights:
                        InsightsMainPanelView(
                            selectedSessionId: selectedInsightSessionId,
                            onNavigateToSession: onNavigateToSession
                        )
                    }
                }
            case .sessions:
                if let session = store.selectedSession {
                    SessionDetailTabView(session: session)
                } else {
                    EmptyStateView(
                        icon: "text.line.first.and.arrowtriangle.forward",
                        title: "Select a session",
                        message: "Choose a session from the sidebar to view its conversation."
                    )
                }
            case .tools:
                if let session = store.selectedSession {
                    ToolsMainPanelView(session: session)
                        .id(session.id)
                } else {
                    EmptyStateView(
                        icon: "wrench.and.screwdriver",
                        title: "Select a session",
                        message: "Choose a session from the sidebar to audit its tool usage."
                    )
                }
            case .plans:
                PlansMainPanelView(
                    selectedPlanFilename: $selectedPlanFilename,
                    planDetail: store.selectedPlanDetail,
                    isLoading: store.plansLoading
                )
            case .timeline:
                TimelineMainPanelView(
                    entries: store.timelineEntries,
                    isLoading: store.timelineLoading,
                    onNavigateToSession: onNavigateToSession
                )
            case .tasksJobs:
                TasksJobsMainPanelView(
                    selection: selectedTasksJobsItem,
                    onNavigateToSession: onNavigateToSession
                )
            case .cowork:
                CoworkMainPanelView(
                    sessions: store.coworkSessions,
                    parsedSessionsByID: store.coworkParsedSessionsByID,
                    pricingTable: store.pricingTable,
                    selectedSessionId: $selectedCoworkSessionId
                )
            case .hooks:
                HooksMainPanelView(
                    hookGroups: store.hookGroups,
                    runtimeAggregates: store.hookRuntimeAggregates,
                    selectedEventId: selectedHookEventId
                )
            case .commands:
                CommandsMainPanelView(
                    commands: store.commands,
                    selectedCommandName: $selectedCommandName
                )
            case .skills:
                SkillsMainPanelView(
                    skills: store.skills,
                    selectedSkillName: $selectedSkillName
                )
            case .agents:
                AgentsMainPanelView(
                    agents: store.agents,
                    selectedAgentName: $selectedAgentName
                )
            case .plugins:
                PluginsMainPanelView(
                    plugins: store.plugins,
                    lintResults: store.lintResults,
                    selectedPluginId: $selectedPluginId
                )
            case .mcps:
                McpsMainPanelView(
                    mcpServers: store.mcpServers,
                    selectedMcpName: selectedMcpName
                )
            case .memory:
                MemoryMainPanelView(
                    memoryFiles: store.memoryFiles,
                    selectedMemoryId: $selectedMemoryId
                )
            case .canon:
                CanonMainPanelView(selectedProjectId: selectedCanonProjectId)
            case .configHealth:
                switch healthSection {
                case .health:
                    ConfigHealthMainPanelView(
                        lintResults: store.lintResults,
                        lintSummary: store.lintSummary,
                        isLoading: store.lintLoading,
                        isSecretScanLoading: store.secretScanLoading,
                        selectedResultId: $selectedLintResultId,
                        hiddenSeverities: $hiddenLintSeverities,
                        selectedItem: selectedHealthItem,
                        onRescan: {
                            Task {
                                await store.runConfigLint(projectId: selectedProjectId)
                            }
                        },
                        onNavigateToSession: onNavigateToSession
                    )
                case .hardening:
                    HardeningMainPanelView(
                        lintResults: store.lintResults,
                        isLoading: store.lintLoading,
                        selectedResultId: $selectedLintResultId,
                        onRescan: {
                            Task {
                                await store.runConfigLint(projectId: selectedProjectId)
                            }
                        }
                    )
                case .routing:
                    RoutingMainPanelView(
                        lintResults: store.lintResults,
                        isLoading: store.lintLoading,
                        selectedResultId: $selectedLintResultId,
                        onRescan: {
                            Task {
                                await store.runConfigLint(projectId: selectedProjectId)
                            }
                        }
                    )
                }
            case .settings:
                SettingsMainPanelView(selectedSection: $selectedSettingsSection)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SessionDetailTabView: View {
    let session: ParsedSession
    @Environment(SessionStore.self) private var store
    @State private var selectedTab: SessionTab = .chat
    /// Set by the Files tab's jump-to-chat; ChatView consumes and clears it.
    @State private var chatScrollTargetUuid: String?

    enum SessionTab: String, CaseIterable {
        case chat = "Chat"
        case files = "Files"
        case context = "Context"
        case agentTree = "Agent Tree"
    }

    private var availableTabs: [SessionTab] {
        store.hasSubagentFiles(sessionId: session.id, projectId: session.projectId)
            ? SessionTab.allCases
            : [.chat, .files, .context]
    }

    /// Computed instead of an onChange reset so switching to a session
    /// without subagents while Agent Tree is selected never renders an
    /// out-of-set tab for a frame.
    private var effectiveTab: SessionTab {
        availableTabs.contains(selectedTab) ? selectedTab : .chat
    }

    /// Provenance (worktree, PR) is stamped on the summary, not the parsed session.
    private var summary: SessionSummary? {
        (store.sessionsByProject[session.projectId] ?? []).first { $0.id == session.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: Binding(
                    get: { effectiveTab },
                    set: { selectedTab = $0 }
                )) {
                    ForEach(availableTabs, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: CGFloat(availableTabs.count) * 110)

                if let summary {
                    provenanceChips(summary)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            switch effectiveTab {
            case .chat:
                ChatView(
                    session: session,
                    scrollTargetUuid: $chatScrollTargetUuid,
                    onOpenFilesTab: { selectedTab = .files }
                )
                .id(session.id)
            case .files:
                SessionFilesView(
                    session: session,
                    onJumpToChat: { uuid in
                        chatScrollTargetUuid = uuid
                        selectedTab = .chat
                    }
                )
                .id(session.id)
            case .context:
                ContextPressureView(session: session)
                    .id(session.id)
            case .agentTree:
                AgentTreeView(session: session)
                    .id(session.id)
            }
        }
    }

    /// Where this session ran and what it opened, from the transcript's
    /// worktree-state and pr-link records.
    @ViewBuilder
    private func provenanceChips(_ summary: SessionSummary) -> some View {
        if let name = summary.worktreeName {
            Label(name, systemImage: "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help(summary.worktreeBranch.map { "Branch \($0)" } ?? "Worktree checkout")
        }

        if let urlString = summary.prUrl, let url = URL(string: urlString) {
            Link(destination: url) {
                Label(summary.prNumber.map { "#\($0)" } ?? "PR", systemImage: "arrow.triangle.pull")
                    .font(.system(size: 11))
            }
            .help(urlString)
        }
    }
}

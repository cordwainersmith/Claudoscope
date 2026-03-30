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
    let selectedMcpName: String?
    @Binding var selectedMemoryId: String?

    // Config Health
    @Binding var selectedLintResultId: String?
    @Binding var hiddenLintSeverities: Set<LintSeverity>
    let selectedHealthItem: String?
    let selectedProjectId: String?

    // Settings
    @Binding var selectedSettingsSection: String?

    // Session navigation from config health (projectId, sessionId, subagentFileName?)
    var onNavigateToSession: ((String, String, String?) -> Void)?

    var body: some View {
        Group {
            switch rail {
            case .analytics:
                AnalyticsDetailView()
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
                    isLoading: store.timelineLoading
                )
            case .hooks:
                HooksMainPanelView(
                    hookGroups: store.hookGroups,
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
            case .configHealth:
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

    enum SessionTab: String, CaseIterable {
        case chat = "Chat"
        case agentTree = "Agent Tree"
    }

    private var showAgentTreeTab: Bool {
        store.hasSubagentFiles(sessionId: session.id, projectId: session.projectId)
    }

    var body: some View {
        VStack(spacing: 0) {
            if showAgentTreeTab {
                Picker("", selection: $selectedTab) {
                    ForEach(SessionTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }

            switch selectedTab {
            case .chat:
                ChatView(session: session)
            case .agentTree:
                AgentTreeView(session: session)
            }
        }
    }
}

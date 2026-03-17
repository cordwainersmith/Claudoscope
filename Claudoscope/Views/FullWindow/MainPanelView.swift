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

    // Session navigation from config health
    var onNavigateToSession: ((String, String) -> Void)?

    var body: some View {
        Group {
            switch rail {
            case .analytics:
                AnalyticsDetailView()
            case .sessions:
                if let session = store.selectedSession {
                    ChatView(session: session)
                } else {
                    EmptyStateView(
                        icon: "text.line.first.and.arrowtriangle.forward",
                        title: "Select a session",
                        message: "Choose a session from the sidebar to view its conversation."
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

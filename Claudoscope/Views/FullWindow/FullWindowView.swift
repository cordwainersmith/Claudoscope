import SwiftUI

struct FullWindowView: View {
    @Environment(SessionStore.self) private var store
    @State private var selectedRail: RailItem = .analytics
    @State private var selectedProjectId: String?
    @State private var selectedSessionId: String?
    @State private var savedSelections: [RailItem: (projectId: String?, sessionId: String?)] = [:]

    // Plans state
    @State private var selectedPlanFilename: String?

    // Config state
    @State private var selectedHookEventId: String?
    @State private var selectedCommandName: String?
    @State private var selectedSkillName: String?
    @State private var selectedMcpName: String?
    @State private var selectedMemoryId: String?
    @State private var selectedMemoryProjectId: String? // nil = global

    // Settings state
    @State private var selectedSettingsSection: String?

    var body: some View {
        HStack(spacing: 0) {
            // Rail: 48px fixed
            RailView(selected: $selectedRail)

            Divider()

            // Sidebar: 240px
            SidebarView(
                rail: selectedRail,
                selectedProjectId: $selectedProjectId,
                selectedSessionId: $selectedSessionId,
                selectedPlanFilename: $selectedPlanFilename,
                selectedHookEventId: $selectedHookEventId,
                selectedCommandName: $selectedCommandName,
                selectedSkillName: $selectedSkillName,
                selectedMcpName: $selectedMcpName,
                selectedMemoryId: $selectedMemoryId,
                selectedMemoryProjectId: $selectedMemoryProjectId,
                selectedSettingsSection: $selectedSettingsSection
            )

            Divider()

            // Main panel: flexible
            MainPanelView(
                rail: selectedRail,
                selectedPlanFilename: $selectedPlanFilename,
                selectedHookEventId: selectedHookEventId,
                selectedCommandName: $selectedCommandName,
                selectedSkillName: $selectedSkillName,
                selectedMcpName: selectedMcpName,
                selectedMemoryId: $selectedMemoryId,
                selectedSettingsSection: $selectedSettingsSection
            )
        }
        .onChange(of: selectedRail) { oldRail, newRail in
            // Save current selection
            savedSelections[oldRail] = (selectedProjectId, selectedSessionId)
            // Restore previous selection for new rail
            if let saved = savedSelections[newRail] {
                selectedProjectId = saved.projectId
                selectedSessionId = saved.sessionId
            } else {
                selectedProjectId = nil
                selectedSessionId = nil
            }

            // Fire-and-forget data loading (don't block the UI)
            loadDataForRail(newRail)
        }
        .onChange(of: selectedSessionId) { _, newId in
            if let sessionId = newId, let projectId = selectedProjectId {
                Task {
                    await store.loadSession(id: sessionId, projectId: projectId)
                }
            }
        }
        .onChange(of: selectedPlanFilename) { _, newFilename in
            if let filename = newFilename {
                Task {
                    await store.loadPlanDetail(filename: filename)
                }
            } else {
                store.selectedPlanDetail = nil
            }
        }
        .onChange(of: selectedMemoryProjectId) { _, _ in
            Task {
                await store.loadMemoryFiles(projectId: selectedMemoryProjectId)
            }
        }
    }

    private func loadDataForRail(_ rail: RailItem) {
        Task.detached {
            switch rail {
            case .plans:
                await store.loadPlans()
            case .timeline:
                await store.loadTimeline()
            case .memory:
                await store.loadMemoryFiles(projectId: selectedMemoryProjectId)
                await store.loadConfig(projectId: selectedProjectId)
            case .hooks, .commands, .mcps, .skills, .settings:
                await store.loadConfig(projectId: selectedProjectId)
            default:
                break
            }
        }
    }
}

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

    // Config Health state
    @State private var selectedLintResultId: String?
    @State private var hiddenLintSeverities: Set<LintSeverity> = []
    @State private var selectedHealthItem: String?

    // Command palette
    @State private var showCommandPalette = false

    // Pending navigation (deferred until after rail change)
    @State private var pendingNavigation: (projectId: String, sessionId: String)?
    @State private var pendingSubagentFileName: String?

    // Timeline state
    @State private var selectedTimelineDay: String?

    // Settings state
    @State private var selectedSettingsSection: String?

    // Sidebar resize
    @SceneStorage("sidebarWidth") private var sidebarWidth: Double = 240
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        ZStack {
            threeColumnLayout
            commandPaletteLayer
        }
        .onChange(of: selectedRail) { oldRail, newRail in
            // Save current selection
            savedSelections[oldRail] = (selectedProjectId, selectedSessionId)

            // Apply pending navigation or restore previous selection
            if let nav = pendingNavigation {
                selectedProjectId = nav.projectId
                selectedSessionId = nav.sessionId
                pendingNavigation = nil
            } else if let saved = savedSelections[newRail] {
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
                let subagent = pendingSubagentFileName
                pendingSubagentFileName = nil
                Task {
                    await store.loadSession(id: sessionId, projectId: projectId, subagentFileName: subagent)
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
        .task(id: store.pendingSettingsNavigation) {
            guard store.pendingSettingsNavigation != nil else { return }
            selectedRail = .settings
        }
        .background {
            // Hidden button to capture Cmd+K globally
            Button("") { showCommandPalette = true }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
    }

    private var threeColumnLayout: some View {
        HStack(spacing: 0) {
            RailView(selected: $selectedRail)

            Divider()

            SidebarView(
                rail: selectedRail,
                width: sidebarWidth,
                selectedProjectId: $selectedProjectId,
                selectedSessionId: $selectedSessionId,
                selectedPlanFilename: $selectedPlanFilename,
                selectedHookEventId: $selectedHookEventId,
                selectedCommandName: $selectedCommandName,
                selectedSkillName: $selectedSkillName,
                selectedMcpName: $selectedMcpName,
                selectedMemoryId: $selectedMemoryId,
                selectedMemoryProjectId: $selectedMemoryProjectId,
                selectedSettingsSection: $selectedSettingsSection,
                selectedLintResultId: $selectedLintResultId,
                hiddenLintSeverities: $hiddenLintSeverities,
                selectedHealthItem: $selectedHealthItem,
                selectedTimelineDay: $selectedTimelineDay
            )

            SidebarResizeHandle(sidebarWidth: $sidebarWidth, dragStartWidth: $dragStartWidth)

            MainPanelView(
                rail: selectedRail,
                selectedPlanFilename: $selectedPlanFilename,
                selectedHookEventId: selectedHookEventId,
                selectedCommandName: $selectedCommandName,
                selectedSkillName: $selectedSkillName,
                selectedMcpName: selectedMcpName,
                selectedMemoryId: $selectedMemoryId,
                selectedLintResultId: $selectedLintResultId,
                hiddenLintSeverities: $hiddenLintSeverities,
                selectedHealthItem: selectedHealthItem,
                selectedProjectId: selectedProjectId,
                selectedSettingsSection: $selectedSettingsSection,
                onNavigateToSession: { projectId, sessionId, subagentFileName in
                    pendingSubagentFileName = subagentFileName
                    pendingNavigation = (projectId, sessionId)
                    selectedRail = .sessions
                }
            )
        }
    }

    @ViewBuilder
    private var commandPaletteLayer: some View {
        if showCommandPalette {
            CommandPaletteOverlay(
                isPresented: $showCommandPalette,
                selectedRail: $selectedRail,
                selectedProjectId: $selectedProjectId,
                selectedSessionId: $selectedSessionId
            )
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
            case .configHealth:
                await store.runConfigLintIfNeeded(projectId: selectedProjectId)
            case .hooks, .commands, .mcps, .skills, .settings:
                await store.loadConfig(projectId: selectedProjectId)
            case .analytics, .sessions, .tools:
                break
            }
        }
    }
}

// MARK: - Sidebar Resize Handle

private struct SidebarResizeHandle: View {
    @Binding var sidebarWidth: Double
    @Binding var dragStartWidth: CGFloat?
    @State private var isHovered = false

    private let minWidth: CGFloat = 180
    private let maxWidth: CGFloat = 400
    private let defaultWidth: CGFloat = 240

    var body: some View {
        Rectangle()
            .fill(isHovered ? Color.accentColor.opacity(0.3) : .clear)
            .frame(width: 5)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartWidth == nil {
                            dragStartWidth = sidebarWidth
                        }
                        let newWidth = (dragStartWidth ?? sidebarWidth) + value.translation.width
                        sidebarWidth = min(maxWidth, max(minWidth, newWidth))
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    sidebarWidth = defaultWidth
                }
            }
    }
}

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

    // Canon state
    @State private var selectedCanonProjectId: String?

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

    // Cowork state
    @State private var selectedCoworkSessionId: String?

    // Plugins state
    @State private var selectedPluginId: String?

    // Sidebar resize
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 240
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        ZStack {
            threeColumnLayout
            commandPaletteLayer
        }
        .overlay(alignment: .top) {
            // Reconcile visibility is gated on total > 0 so a warm no-change
            // launch (0 changed files) never flashes the banner.
            let showScanBanner = store.isLoading || (store.isReconciling && store.scanSessionsTotal > 0)
            if showScanBanner {
                ScanProgressBanner()
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.3), value: showScanBanner)
            }
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
        .onAppear { applyRequestedRail() }
        .onChange(of: store.requestedRail) { _, _ in applyRequestedRail() }
        .onChange(of: SessionSelection(projectId: selectedProjectId, sessionId: selectedSessionId)) { _, selection in
            if let sessionId = selection.sessionId, let projectId = selection.projectId {
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
        .onChange(of: selectedCanonProjectId) { _, _ in
            Task {
                await store.loadCanon(projectId: selectedCanonProjectId)
            }
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
            RailView(selected: $selectedRail, coworkVisible: store.coworkAvailability.isReady)

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
                selectedCanonProjectId: $selectedCanonProjectId,
                selectedSettingsSection: $selectedSettingsSection,
                selectedLintResultId: $selectedLintResultId,
                hiddenLintSeverities: $hiddenLintSeverities,
                selectedHealthItem: $selectedHealthItem,
                selectedTimelineDay: $selectedTimelineDay,
                selectedCoworkSessionId: $selectedCoworkSessionId,
                selectedPluginId: $selectedPluginId
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
                selectedCanonProjectId: selectedCanonProjectId,
                selectedLintResultId: $selectedLintResultId,
                hiddenLintSeverities: $hiddenLintSeverities,
                selectedHealthItem: selectedHealthItem,
                selectedProjectId: selectedProjectId,
                selectedSettingsSection: $selectedSettingsSection,
                selectedCoworkSessionId: $selectedCoworkSessionId,
                selectedPluginId: $selectedPluginId,
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
                selectedSessionId: $selectedSessionId,
                coworkVisible: store.coworkAvailability.isReady
            )
        }
    }

    /// Applies a rail navigation requested from outside the window (menu bar
    /// popover). Clears the request so it fires once. Switching the rail routes
    /// through the existing selectedRail onChange for bookkeeping and data load.
    private func applyRequestedRail() {
        guard let requested = store.requestedRail else { return }
        store.requestedRail = nil
        if selectedRail != requested {
            selectedRail = requested
        } else {
            loadDataForRail(requested)
        }
    }

    private func loadDataForRail(_ rail: RailItem) {
        Task {
            switch rail {
            case .plans:
                await store.loadPlans()
            case .timeline:
                await store.loadTimeline()
            case .memory:
                await store.loadMemoryFiles(projectId: selectedMemoryProjectId)
                await store.loadConfig(projectId: selectedProjectId)
            case .canon:
                await store.refreshCanonDetection()
                await store.loadCanon(projectId: selectedCanonProjectId)
            case .configHealth, .hardening:
                await store.runConfigLintIfNeeded(projectId: selectedProjectId)
            case .plugins:
                await store.loadConfig(projectId: selectedProjectId)
                // Surface PLG dependency findings in the plugin detail panel.
                await store.runConfigLintIfNeeded(projectId: selectedProjectId)
            case .hooks, .commands, .mcps, .skills, .settings:
                await store.loadConfig(projectId: selectedProjectId)
            case .cowork:
                await store.loadCowork()
            case .analytics, .sessions, .tools:
                break
            }
        }
    }
}

private struct SessionSelection: Equatable {
    let projectId: String?
    let sessionId: String?
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

import AppKit
import Foundation
import Combine

enum AppAppearance: String, CaseIterable {
    case system
    case light
    case dark

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Central observable store for all session/project data.
/// Owns the file watcher and Combine pipeline for reactive updates.
@Observable
final class SessionStore {
    var projects: [Project] = []
    var sessionsByProject: [String: [SessionSummary]] = [:]
    var hasActiveSession: Bool = false
    var analyticsData: AnalyticsData = .empty
    var selectedAnalyticsProjectId: String?  // nil = all projects
    var analyticsTimeRange: AnalyticsTimeRange = .thirtyDays
    var analyticsCustomFrom: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    var analyticsCustomTo: Date = Date()
    var isLoading: Bool = true
    var selectedSession: ParsedSession?

    // Plans data
    var plans: [PlanSummary] = []
    var selectedPlanDetail: PlanDetail?
    var plansLoading: Bool = false

    // Timeline data
    var timelineEntries: [HistoryEntry] = []
    var timelineLoading: Bool = false

    // Config data
    var hookGroups: [HookEventGroup] = []
    var commands: [CommandEntry] = []
    var skills: [SkillEntry] = []
    var mcpServers: [McpServerEntry] = []
    var memoryFiles: [MemoryFile] = []
    var extendedConfig: ExtendedConfig?
    var configLoading: Bool = false

    // Appearance
    var appearance: AppAppearance = .system

    // Pricing configuration
    var pricingProvider: PricingProvider = .vertex
    var pricingRegion: VertexRegion = .global

    var pricingTable: [String: ModelPricing] {
        PricingTables.table(provider: pricingProvider, region: pricingRegion)
    }

    private let claudeDir: URL
    private let parser = SessionParser()
    private let cache = SessionCache()
    private let watcher: ClaudeFileWatcher
    private let plansService: PlansService
    private let timelineService: TimelineService
    private let configService: ConfigService
    private var cancellables = Set<AnyCancellable>()

    /// All sessions flattened with their project
    var allSessionsWithProjects: [(session: SessionSummary, project: Project)] {
        var result: [(SessionSummary, Project)] = []
        for project in projects {
            if let sessions = sessionsByProject[project.id] {
                for session in sessions {
                    result.append((session, project))
                }
            }
        }
        return result
    }

    /// Today's sessions
    var todaySessions: [SessionSummary] {
        let todayPrefix = todayDateString()
        return allSessionsWithProjects
            .map(\.session)
            .filter { $0.lastTimestamp.hasPrefix(todayPrefix) }
    }

    /// Recent sessions (last 3, any date)
    var recentSessions: [SessionSummary] {
        Array(
            allSessionsWithProjects
                .map(\.session)
                .sorted { $0.lastTimestamp > $1.lastTimestamp }
                .prefix(3)
        )
    }

    /// Today's stats
    var todayTokens: Int {
        todaySessions.reduce(0) { $0 + $1.totalInputTokens + $1.totalOutputTokens }
    }

    var todayCost: Double {
        todaySessions.reduce(0) { $0 + $1.estimatedCost }
    }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.claudeDir = home.appendingPathComponent(".claude")
        self.watcher = ClaudeFileWatcher(claudeDir: claudeDir)
        self.plansService = PlansService(claudeDir: claudeDir)
        self.timelineService = TimelineService(claudeDir: claudeDir)
        self.configService = ConfigService(claudeDir: claudeDir)

        setupWatcher()
        performInitialScan()
    }

    private func setupWatcher() {
        watcher.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard let self else { return }
                Task {
                    await self.handleFileChange(change)
                }
            }
            .store(in: &cancellables)

        watcher.start()
    }

    private func performInitialScan() {
        Task {
            let scanner = ProjectScanner(
                claudeDir: claudeDir,
                parser: parser,
                pricingTable: pricingTable
            )
            let (scannedProjects, scannedSessions) = await scanner.scan()

            await MainActor.run {
                self.projects = scannedProjects
                self.sessionsByProject = scannedSessions
                self.isLoading = false
                self.checkActiveSession()
                self.recomputeAnalytics()
            }
        }
    }

    private func handleFileChange(_ change: FileChange) async {
        switch change {
        case .sessionUpdated(let url), .sessionCreated(let url):
            let sessionId = url.deletingPathExtension().lastPathComponent
            let projectId = url.deletingLastPathComponent().lastPathComponent

            // Invalidate cache
            await cache.invalidate(sessionId)

            // Re-parse metadata
            do {
                let summary = try await parser.parseMetadata(
                    url: url,
                    sessionId: sessionId,
                    pricingTable: pricingTable
                )

                await MainActor.run {
                    // Update or insert session
                    var sessions = self.sessionsByProject[projectId] ?? []
                    if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
                        sessions[idx] = summary
                    } else {
                        sessions.insert(summary, at: 0)
                    }
                    self.sessionsByProject[projectId] = sessions

                    // Ensure project exists
                    if !self.projects.contains(where: { $0.id == projectId }) {
                        let project = Project(
                            id: projectId,
                            name: decodeProjectName(projectId),
                            path: url.deletingLastPathComponent().path,
                            sessionCount: sessions.count
                        )
                        self.projects.append(project)
                        self.projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    }

                    self.checkActiveSession()
                    self.recomputeAnalytics()
                }
            } catch {
                // Ignore parse errors for individual file updates
            }

        case .configChanged:
            // Config changes handled in later phases
            break
        }
    }

    private func checkActiveSession() {
        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        hasActiveSession = allSessionsWithProjects.contains { pair in
            guard let date = isoFormatter.date(from: pair.session.lastTimestamp) else { return false }
            return now.timeIntervalSince(date) < 60
        }
    }

    func recomputeAnalytics() {
        let sessions: [(session: SessionSummary, project: Project)]
        if let projectId = selectedAnalyticsProjectId {
            sessions = allSessionsWithProjects.filter { $0.project.id == projectId }
        } else {
            sessions = allSessionsWithProjects
        }

        let (from, to) = analyticsTimeRange.dateRange(
            customFrom: analyticsCustomFrom,
            customTo: analyticsCustomTo
        )

        analyticsData = AnalyticsEngine.compute(
            sessions: sessions,
            pricingTable: pricingTable,
            from: from,
            to: to
        )
    }

    /// Analytics for the sidebar (always all projects, 30d, for cost ranking)
    var sidebarAnalyticsData: AnalyticsData {
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())
        return AnalyticsEngine.compute(
            sessions: allSessionsWithProjects,
            pricingTable: pricingTable,
            from: thirtyDaysAgo,
            to: nil
        )
    }

    func loadSession(id: String, projectId: String) async {
        // Check cache first
        if let cached = await cache.get(id) {
            await MainActor.run {
                self.selectedSession = cached
            }
            return
        }

        let fileURL = claudeDir
            .appendingPathComponent("projects")
            .appendingPathComponent(projectId)
            .appendingPathComponent("\(id).jsonl")

        do {
            let session = try await parser.parse(url: fileURL, sessionId: id)
            await cache.set(id, value: session)
            await MainActor.run {
                self.selectedSession = session
            }
        } catch {
            // Handle error
        }
    }

    private func todayDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    // MARK: - Plans

    func loadPlans() async {
        await MainActor.run { plansLoading = true }
        let loaded = await plansService.loadPlans()
        await MainActor.run {
            self.plans = loaded
            self.plansLoading = false
        }
    }

    func loadPlanDetail(filename: String) async {
        let detail = await plansService.loadPlanDetail(filename: filename)
        await MainActor.run {
            self.selectedPlanDetail = detail
        }
    }

    // MARK: - Timeline

    func loadTimeline() async {
        await MainActor.run { timelineLoading = true }
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())
        let loaded = await timelineService.loadEntries(since: sevenDaysAgo)
        await MainActor.run {
            self.timelineEntries = loaded
            self.timelineLoading = false
        }
    }

    // MARK: - Config (hooks, commands, MCPs, memory)

    func loadConfig(projectId: String?) async {
        await MainActor.run { configLoading = true }
        let hooks = await configService.loadHooks()
        let cmds = await configService.loadCommands()
        let skls = await configService.loadSkills()
        let mcps = await configService.loadMcpServers()
        let memory = await configService.loadMemoryFiles(projectId: projectId)
        let extended = await configService.loadExtendedConfig()
        await MainActor.run {
            self.hookGroups = hooks
            self.commands = cmds
            self.skills = skls
            self.mcpServers = mcps
            self.memoryFiles = memory
            self.extendedConfig = extended
            self.configLoading = false
        }
    }
}

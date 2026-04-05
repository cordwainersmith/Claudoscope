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

enum SettingsDestination: Equatable {
    case workspaces
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

    // Observability data
    var subagentTree: SubagentNode? = nil
    var sessionBadges: [String: SessionBadgeData] = [:]

    // Lint data
    var lintResults: [LintResult] = []
    var lintSummary: LintSummary = .empty
    var lintLoading: Bool = false
    var secretScanLoading: Bool = false

    // Real-time secret alert
    var activeSecretAlert: SecretAlert?
    var onSecretAlert: ((SecretAlert) -> Void)?
    private var alertedSecrets: Set<String> = []

    // Lint caching
    private var lintResultsValid: Bool = false

    // Real-time secret scanning toggle
    var realtimeSecretScanEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "realtimeSecretScanEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "realtimeSecretScanEnabled") }
    }

    // Deep-link navigation
    var pendingSettingsNavigation: SettingsDestination? = nil

    // Appearance
    var appearance: AppAppearance = .system

    // Pricing configuration
    var pricingProvider: PricingProvider = .anthropic
    var pricingRegion: VertexRegion = .global

    var pricingTable: [String: ModelPricing] {
        PricingTables.table(provider: pricingProvider, region: pricingRegion)
    }

    private(set) var claudeDir: URL
    private let parser = SessionParser()
    private let cache = SessionCache()
    @ObservationIgnored private var watcher: ClaudeFileWatcher
    @ObservationIgnored private var plansService: PlansService
    @ObservationIgnored private var timelineService: TimelineService
    @ObservationIgnored private var configService: ConfigService
    private let linterService = ConfigLinterService()
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var watcherCancellable: AnyCancellable?

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
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return allSessionsWithProjects
            .map(\.session)
            .filter { session in
                guard let date = isoFormatter.date(from: session.lastTimestamp) else { return false }
                return date >= startOfToday
            }
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
        todaySessions.reduce(0.0) { $0 + $1.estimatedCost }
    }

    @MainActor
    init(workspaceManager: WorkspaceManager) {
        let dir = URL(fileURLWithPath: workspaceManager.activeWorkspace.path)
        self.claudeDir = dir
        self.watcher = ClaudeFileWatcher(claudeDir: dir)
        self.plansService = PlansService(claudeDir: dir)
        self.timelineService = TimelineService(claudeDir: dir)
        self.configService = ConfigService(claudeDir: dir)

        if UserDefaults.standard.object(forKey: "realtimeSecretScanEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "realtimeSecretScanEnabled")
        }

        setupWatcher()
        performInitialScan()

        workspaceManager.activeWorkspaceChanged
            .sink { [weak self] workspace in
                Task { @MainActor [weak self] in
                    self?.reloadForWorkspace(workspace)
                }
            }
            .store(in: &cancellables)
    }

    private func setupWatcher() {
        watcherCancellable = watcher.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard let self else { return }
                Task {
                    await self.handleFileChange(change)
                }
            }
        watcher.start()
    }

    @MainActor
    private func reloadForWorkspace(_ workspace: Workspace) {
        // Releasing watcherCancellable lets the old ClaudeFileWatcher deinit,
        // which calls stop() automatically on its FSEvent stream.
        watcherCancellable = nil
        selectedSession = nil
        isLoading = true
        lintResultsValid = false
        plans = []
        timelineEntries = []
        claudeDir = URL(fileURLWithPath: workspace.path)
        watcher = ClaudeFileWatcher(claudeDir: claudeDir)
        plansService = PlansService(claudeDir: claudeDir)
        timelineService = TimelineService(claudeDir: claudeDir)
        configService = ConfigService(claudeDir: claudeDir)
        projects = []
        sessionsByProject = [:]
        setupWatcher()
        performInitialScan()
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

            // Derive projectId by finding the "projects" path component
            let components = url.pathComponents
            let projectId: String
            if let idx = components.lastIndex(of: "projects"), idx + 1 < components.count {
                projectId = components[idx + 1]
            } else {
                projectId = url.deletingLastPathComponent().lastPathComponent
            }

            // Invalidate cache
            await cache.invalidate(sessionId)

            // Reset UUID dedup so re-parsed records aren't skipped
            await parser.resetDedup()

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

            // Invalidate lint cache so next Config Health visit rescans
            await MainActor.run { self.lintResultsValid = false }

            // Real-time secret scan: check last 50 lines for secrets
            await scanForRealtimeSecrets(url: url, sessionId: sessionId, projectId: projectId)

        case .configChanged:
            // Config changes handled in later phases
            break
        }
    }

    private static func readTail(of url: URL, bytes: Int = 131072) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let fileSize = handle.seekToEndOfFile()
        let offset = fileSize > UInt64(bytes) ? fileSize - UInt64(bytes) : 0
        handle.seek(toFileOffset: offset)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        return offset > 0 ? Array(lines.dropFirst().suffix(50)) : Array(lines.suffix(50))
    }

    private func scanForRealtimeSecrets(url: URL, sessionId: String, projectId: String) async {
        guard realtimeSecretScanEnabled else { return }
        guard let lines = Self.readTail(of: url) else { return }

        let findings = await linterService.scanLinesForSecrets(lines)
        guard let finding = findings.first else { return }

        let masked = ConfigLinterService.maskSecret(finding.matchedText)
        let dedupKey = "\(sessionId):\(masked)"

        await MainActor.run {
            guard !alertedSecrets.contains(dedupKey) else { return }
            alertedSecrets.insert(dedupKey)

            // Derive a session title
            let title = sessionsByProject[projectId]?
                .first(where: { $0.id == sessionId })?.title ?? sessionId

            let isSubagent = url.pathComponents.contains("subagents")
            let alert = SecretAlert(
                checkId: finding.checkId,
                patternName: finding.patternName,
                maskedValue: masked,
                sessionTitle: title,
                projectId: projectId,
                sessionId: sessionId,
                isSubagent: isSubagent
            )
            activeSecretAlert = alert
            onSecretAlert?(alert)
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

    /// Re-scan all sessions with the current pricing table (e.g. after pricing provider change)
    func rescanAllSessions() {
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
                self.recomputeAnalytics()
            }
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

    func loadSession(id: String, projectId: String, subagentFileName: String? = nil) async {
        let cacheKey = if let subagentFileName {
            "\(id)/subagents/\(subagentFileName)"
        } else {
            id
        }

        // Check cache first
        if let cached = await cache.get(cacheKey) {
            await MainActor.run {
                self.selectedSession = cached
            }
            return
        }

        let fileURL: URL
        if let subagentFileName {
            fileURL = claudeDir
                .appendingPathComponent("projects")
                .appendingPathComponent(projectId)
                .appendingPathComponent(id)
                .appendingPathComponent("subagents")
                .appendingPathComponent(subagentFileName)
        } else {
            fileURL = claudeDir
                .appendingPathComponent("projects")
                .appendingPathComponent(projectId)
                .appendingPathComponent("\(id).jsonl")
        }

        let parseSessionId = if let subagentFileName {
            String(subagentFileName.dropLast(6)) // drop ".jsonl"
        } else {
            id
        }

        do {
            let parsed = try await parser.parse(url: fileURL, sessionId: parseSessionId)
            let session = if subagentFileName != nil {
                ParsedSession(
                    id: parsed.id,
                    projectId: parsed.projectId,
                    slug: parsed.slug,
                    records: parsed.records,
                    toolResultMap: parsed.toolResultMap,
                    metadata: parsed.metadata,
                    parentSessionId: parsed.parentSessionId,
                    isSubagent: true
                )
            } else {
                parsed
            }
            await cache.set(cacheKey, value: session)
            await MainActor.run {
                self.selectedSession = session
            }
        } catch {
            // Handle error
        }
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

    func loadMemoryFiles(projectId: String?) async {
        let memory = await configService.loadMemoryFiles(projectId: projectId)
        await MainActor.run {
            self.memoryFiles = memory
        }
    }

    // MARK: - Config Lint

    func runConfigLintIfNeeded(projectId: String?) async {
        guard !lintResultsValid else { return }
        await runConfigLint(projectId: projectId)
    }

    func runConfigLint(projectId: String?) async {
        await MainActor.run {
            lintLoading = true
            secretScanLoading = false
        }

        // Capture sessions on MainActor before any await
        let sessions: [SessionSummary] = await MainActor.run {
            if let projectId {
                return sessionsByProject[projectId] ?? []
            } else {
                return sessionsByProject.values.flatMap { $0 }
            }
        }

        // Resolve project root from projectId
        let projectRoot: String?
        if let projectId {
            projectRoot = await configService.decodeProjectPath(projectId)
        } else {
            projectRoot = nil
        }

        // Phase 1 (fast): rules, skills, session health checks
        var fastResults = await linterService.lint(projectRoot: projectRoot, globalClaudeDir: claudeDir)
        let sessionResults = await linterService.lintSessions(sessions)
        fastResults.append(contentsOf: sessionResults)
        fastResults.sort { $0.severity < $1.severity }

        let phase1Results = fastResults
        let phase1Summary = LintSummary.from(results: phase1Results)

        await MainActor.run {
            self.lintResults = phase1Results
            self.lintSummary = phase1Summary
            self.lintLoading = false
            self.secretScanLoading = true
        }

        // Phase 2 (slow): secret scanning in background
        let secretResults = await linterService.lintSessionSecrets(sessions, claudeDir: claudeDir)

        await MainActor.run {
            var allResults = phase1Results
            allResults.append(contentsOf: secretResults)

            // SEC008: correlate ENV_SCRUB not set with actual secret findings
            if allResults.contains(where: { $0.checkId == .CFG006 }) && !secretResults.isEmpty {
                allResults.append(LintResult(
                    severity: .warning,
                    checkId: .SEC008,
                    filePath: "settings.json",
                    message: "\(secretResults.count) credential pattern(s) found in session data while CLAUDE_CODE_SUBPROCESS_ENV_SCRUB is not set. Credentials may leak via Bash tool, hooks, or MCP servers.",
                    fix: "Add CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 to settings.json env section to prevent credential leakage into subprocess environments.",
                    displayPath: "settings.json"
                ))
            }

            allResults.sort { $0.severity < $1.severity }
            self.lintResults = allResults
            self.lintSummary = LintSummary.from(results: allResults)
            self.secretScanLoading = false
            self.lintResultsValid = true
        }
    }

    func loadConfig(projectId: String?) async {
        await MainActor.run { configLoading = true }
        let hooks = await configService.loadHooks()
        let cmds = await configService.loadCommands()
        let skls = await configService.loadSkills()
        let projectPath = projectId.flatMap { id in projects.first(where: { $0.id == id })?.path }
        let mcps = await configService.loadMcpServers(projectPath: projectPath)
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

    // MARK: - Subagent Tree

    func loadSubagentTree(sessionId: String, projectId: String) async {
        let fm = FileManager.default
        let subagentsDir = claudeDir
            .appendingPathComponent("projects")
            .appendingPathComponent(projectId)
            .appendingPathComponent(sessionId)
            .appendingPathComponent("subagents")

        guard fm.fileExists(atPath: subagentsDir.path) else {
            await MainActor.run { self.subagentTree = nil }
            return
        }

        do {
            let subFiles = try fm.contentsOfDirectory(atPath: subagentsDir.path)
                .filter { $0.hasSuffix(".jsonl") }

            var subagentSummaries: [SessionSummary] = []
            for file in subFiles {
                let subId = String(file.dropLast(6))
                let url = subagentsDir.appendingPathComponent(file)
                if let summary = try? await parser.parseMetadata(
                    url: url,
                    sessionId: subId,
                    pricingTable: pricingTable
                ) {
                    subagentSummaries.append(summary)
                }
            }

            if let parentSessions = sessionsByProject[projectId],
               let parentSummary = parentSessions.first(where: { $0.id == sessionId }) {
                let tree = ObservabilityAnalyzer.buildSubagentTree(
                    parentSession: parentSummary,
                    subagentSummaries: subagentSummaries
                )
                await MainActor.run { self.subagentTree = tree }
            } else {
                await MainActor.run { self.subagentTree = nil }
            }
        } catch {
            await MainActor.run { self.subagentTree = nil }
        }
    }

    func hasSubagentFiles(sessionId: String, projectId: String) -> Bool {
        let subagentsDir = claudeDir
            .appendingPathComponent("projects")
            .appendingPathComponent(projectId)
            .appendingPathComponent(sessionId)
            .appendingPathComponent("subagents")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: subagentsDir.path) else {
            return false
        }
        return files.contains { $0.hasSuffix(".jsonl") }
    }
}

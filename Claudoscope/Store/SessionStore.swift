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
@MainActor @Observable
final class SessionStore {
    var projects: [Project] = []
    var sessionsByProject: [String: [SessionSummary]] = [:]
    var hasActiveSession: Bool = false
    var analyticsData: AnalyticsData = .empty
    var dataCoverage: DataCoverage?
    var selectedAnalyticsProjectId: String?  // nil = all projects
    var analyticsTimeRange: AnalyticsTimeRange = .thirtyDays
    var analyticsCustomFrom: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    var analyticsCustomTo: Date = Date()
    var isLoading: Bool = true
    var scanSessionsProcessed: Int = 0
    var scanSessionsTotal: Int = 0
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
    var themes: [ThemeFile] = []
    var plugins: [PluginInfo] = []
    var configLoading: Bool = false

    // Cowork data (Claude desktop app's agentic mode, separate from Claude Code)
    var coworkAvailability: CoworkAvailability = .unknown
    var coworkSessions: [CoworkSession] = []
    var coworkParsedSessionsByID: [String: ParsedSession] = [:]
    /// Billing summaries synthesized per Cowork session via parseMetadata.
    /// Consumed ONLY by the menu bar popover (todaySessions/recentSessions/
    /// activeSessions). Must never be merged into allSessionsWithProjects,
    /// sessionsByProject, recomputeAnalytics, or recomputeDataCoverage.
    var coworkSummaries: [SessionSummary] = []
    var coworkLoading: Bool = false

    // Observability data
    var subagentTree: SubagentNode? = nil
    var sessionBadges: [String: SessionBadgeData] = [:]

    // Lint data
    var lintResults: [LintResult] = []
    var lintSummary: LintSummary = .empty
    var lintLoading: Bool = false
    var secretScanLoading: Bool = false

    /// Set to true while HardeningInstaller is mid-install/revert/uninstall.
    /// ClaudeFileWatcher's lint-trigger pipelines short-circuit when this is set
    /// to avoid linting against a partially-written settings.json or CLAUDE.md.
    /// Use `setInstallInProgress(_:)` to flip; it also informs the file watcher
    /// so config events are dropped at the source.
    private(set) var installInProgress: Bool = false

    /// Toggle the install-in-progress flag. MainActor-isolated; also pushes the
    /// state into ClaudeFileWatcher so its FSEvents callback skips configChanged
    /// emissions while the installer is mid-mutation.
    func setInstallInProgress(_ value: Bool) {
        installInProgress = value
        watcher.setInstallInProgress(value)
    }

    // Real-time secret alert
    var activeSecretAlert: SecretAlert?
    var onSecretAlert: ((SecretAlert) -> Void)?
    private var alertedSecrets: [String] = [] {
        didSet { Self.persistAlertedSecrets(alertedSecrets) }
    }

    private static let alertedSecretsKey = "alertedSecretValues"
    private static let alertedSecretsCap = 200

    private static func loadAlertedSecrets() -> [String] {
        let array = UserDefaults.standard.stringArray(forKey: alertedSecretsKey) ?? []
        return Array(array.suffix(alertedSecretsCap))
    }

    private static func persistAlertedSecrets(_ secrets: [String]) {
        UserDefaults.standard.set(secrets, forKey: alertedSecretsKey)
    }

    // Cost alerts: owned by the app, evaluated at the end of recomputeAnalytics().
    @ObservationIgnored var costAlertService: CostAlertService?
    /// The first Cowork merge adds lifetime totals in one jump; it must
    /// rebaseline the spend ledger, not enter the rolling window.
    @ObservationIgnored private var coworkMergedIntoCostLedger = false

    // Lint caching
    private var lintResultsValid: Bool = false

    var realtimeSecretScanEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(realtimeSecretScanEnabled, forKey: Self.realtimeSecretScanKey)
        }
    }

    private static let realtimeSecretScanKey = "realtimeSecretScanEnabled"

    // Appearance
    var appearance: AppAppearance = .system

    // Pricing configuration
    var pricingProvider: PricingProvider = .anthropic
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
    private let linterService = ConfigLinterService()
    private let coworkService = CoworkService()
    private let coworkWatcher = CoworkFileWatcher(supportDir: CoworkService.defaultSupportDir)
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

    /// Today's sessions (CLI + Cowork; Cowork rows carry isCowork = true)
    var todaySessions: [SessionSummary] {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        return (allSessionsWithProjects.map(\.session) + coworkSummaries)
            .filter { session in
                guard let date = ISO8601.parse(session.lastTimestamp) else { return false }
                return date >= startOfToday
            }
    }

    /// Recent sessions (last 3, any date, CLI + Cowork). Subagents are filtered
    /// out — their UUID titles would push real top-level sessions out of the
    /// popover's list.
    var recentSessions: [SessionSummary] {
        Array(
            (allSessionsWithProjects.map(\.session) + coworkSummaries)
                .filter { !$0.isSubagent }
                .sorted { $0.lastTimestamp > $1.lastTimestamp }
                .prefix(3)
        )
    }

    /// LOCAL calendar day (YYYY-MM-DD) of now, matching the day keys the parser
    /// stamps on each `DailyContribution`.
    private static let localDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Today's stats. Only the cost/tokens billed *today* are counted, not the whole
    /// lifetime of a session that merely happens to be active today: a `/resume` of an
    /// older session must not pull its earlier-day spend into today's total.
    var todayTokens: Int {
        Self.dayTotals(sessions: todaySessions, dayKey: Self.localDayFormatter.string(from: Date())).tokens
    }

    var todayCost: Double {
        Self.dayTotals(sessions: todaySessions, dayKey: Self.localDayFormatter.string(from: Date())).cost
    }

    /// Pure fold of one calendar day's billed tokens/cost across a pre-merged
    /// session list. nonisolated + static so unit tests can call it without
    /// constructing a SessionStore (whose init spawns watchers and scans).
    nonisolated static func dayTotals(
        sessions: [SessionSummary],
        dayKey: String
    ) -> (tokens: Int, cost: Double) {
        var tokens = 0
        var cost = 0.0
        for session in sessions {
            for day in session.dailyContributions where day.date == dayKey {
                tokens += day.inputTokens + day.outputTokens
                cost += day.estimatedCost
            }
        }
        return (tokens, cost)
    }

    /// Pure fold of one calendar month's billed tokens/cost. `monthKey` is
    /// "yyyy-MM"; day keys are "yyyy-MM-dd", so a prefix match selects the month.
    nonisolated static func monthTotals(
        sessions: [SessionSummary],
        monthKey: String
    ) -> (tokens: Int, cost: Double) {
        var tokens = 0
        var cost = 0.0
        for session in sessions {
            for day in session.dailyContributions where day.date.hasPrefix(monthKey) {
                tokens += day.inputTokens + day.outputTokens
                cost += day.estimatedCost
            }
        }
        return (tokens, cost)
    }

    /// Sessions eligible for the per-session cost alert: activity within the
    /// last 30 minutes, subagents excluded (their UUID titles make useless
    /// alerts; fan-out spend is the rolling rule's job).
    nonisolated static func recentSessionFigures(
        sessions: [SessionSummary],
        now: Date
    ) -> [CostSessionFigure] {
        sessions.compactMap { session in
            guard !session.isSubagent,
                  let date = ISO8601.parse(session.lastTimestamp),
                  now.timeIntervalSince(date) < 30 * 60 else { return nil }
            return CostSessionFigure(
                id: session.id,
                title: session.title,
                cost: session.estimatedCost,
                tokens: session.totalInputTokens + session.totalOutputTokens
            )
        }
    }

    func clearAlertedSecrets() {
        alertedSecrets.removeAll()
    }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.claudeDir = home.appendingPathComponent(".claude")
        self.watcher = ClaudeFileWatcher(claudeDir: claudeDir)
        self.plansService = PlansService(claudeDir: claudeDir)
        self.timelineService = TimelineService(claudeDir: claudeDir)
        self.configService = ConfigService(claudeDir: claudeDir)
        self.alertedSecrets = Self.loadAlertedSecrets()

        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.realtimeSecretScanKey) == nil {
            self.realtimeSecretScanEnabled = true
            defaults.set(true, forKey: Self.realtimeSecretScanKey)
        } else {
            self.realtimeSecretScanEnabled = defaults.bool(forKey: Self.realtimeSecretScanKey)
        }

        setupWatcher()
        setupCoworkWatcher()
        performInitialScan()
        Task { await loadCowork() }
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

        // Debounced config reload: collapse bursts of distinct settings.json /
        // plugin manifest events into a single loadConfig call. The watcher itself
        // already debounces per-path at 300ms; this debounces across paths so
        // editing 3 different files doesn't trigger 3 sequential 6-step reloads.
        watcher.changes
            .compactMap { change -> Void? in
                if case .configChanged = change { return () }
                return nil
            }
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task {
                    await self.loadConfig(projectId: self.selectedAnalyticsProjectId)
                    await self.recomputeDataCoverage()   // picks up cleanupPeriodDays edits
                }
            }
            .store(in: &cancellables)

        if !watcher.start() {
            NSLog("[Claudoscope] File watcher failed to start. File changes will not be detected.")
        }
    }

    private func setupCoworkWatcher() {
        coworkWatcher.changes
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.loadCowork() }
            }
            .store(in: &cancellables)

        if !coworkWatcher.start() {
            // Cowork directory may not exist (Claude desktop app not installed).
            // Not an error; the rail will simply remain hidden.
        }
    }

    /// Reload Cowork availability + sessions + parsed transcripts + popover
    /// summaries. Concurrency cap of 8 mirrors ProjectScanner. Map replacement
    /// is atomic at the end so the UI never sees a half-populated state.
    func loadCowork(rebaselineCostLedger: Bool = false) async {
        coworkLoading = true
        let (availability, sessions) = await coworkService.loadSessions()
        let table = pricingTable

        var parsedMap: [String: ParsedSession] = [:]
        var summaries: [SessionSummary] = []
        await withTaskGroup(of: (String, ParsedSession?, SessionSummary?).self) { group in
            var inFlight = 0
            var iterator = sessions.makeIterator()
            while let session = iterator.next() {
                if inFlight >= 8 {
                    if let result = await group.next() {
                        if let parsed = result.1 { parsedMap[result.0] = parsed }
                        if let summary = result.2 { summaries.append(summary) }
                    }
                    inFlight -= 1
                }
                group.addTask { [coworkService] in
                    let data = await coworkService.loadSessionData(for: session, pricingTable: table)
                    return (session.id, data?.parsed, data?.summary)
                }
                inFlight += 1
            }
            for await (id, parsed, summary) in group {
                if let parsed { parsedMap[id] = parsed }
                if let summary { summaries.append(summary) }
            }
        }
        summaries.sort { $0.lastTimestamp > $1.lastTimestamp }

        self.coworkAvailability = availability
        self.coworkSessions = sessions
        self.coworkParsedSessionsByID = parsedMap
        self.coworkSummaries = summaries
        self.coworkLoading = false

        // Cowork totals contribute to the Analytics page's "Est. Cost" card.
        // Recompute so the breakdown stays in sync when sessions land or change.
        let firstCoworkMerge = !coworkMergedIntoCostLedger
        coworkMergedIntoCostLedger = true
        recomputeAnalytics(rebaselineCostLedger: rebaselineCostLedger || firstCoworkMerge)
    }

    private func performInitialScan() {
        Task {
            let scanner = ProjectScanner(
                claudeDir: claudeDir,
                parser: parser,
                pricingTable: pricingTable
            )
            let (scannedProjects, scannedSessions) = await scanner.scan { [weak self] processed, total in
                self?.scanSessionsProcessed = processed
                self?.scanSessionsTotal = total
            }

            self.projects = scannedProjects
            self.sessionsByProject = scannedSessions
            self.isLoading = false
            self.checkActiveSession()
            self.recomputeAnalytics()
            await self.recomputeDataCoverage()
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

            do {
                let summary = try await parser.parseMetadata(
                    url: url,
                    sessionId: sessionId,
                    pricingTable: pricingTable
                )

                // Re-read after the await so concurrent handlers (or a rescan)
                // that completed during the suspension don't get clobbered.
                var sessions = self.sessionsByProject[projectId] ?? []
                if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
                    sessions[idx] = summary
                } else {
                    sessions.insert(summary, at: 0)
                }
                self.sessionsByProject[projectId] = sessions

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
                // A brand-new transcript can close a coverage gap (a previously
                // missing history session now has a file); recompute on create
                // only — plain updates don't change the known-id set.
                if case .sessionCreated = change {
                    await self.recomputeDataCoverage()
                }
            } catch {
                NSLog("[Claudoscope] Watcher: failed to parse session %@ in project %@: %@",
                      sessionId, projectId, error.localizedDescription)
            }

            // Invalidate lint cache so next Config Health visit rescans
            self.lintResultsValid = false

            // Real-time secret scan: check last 50 lines for secrets
            await scanForRealtimeSecrets(url: url, sessionId: sessionId, projectId: projectId)

        case .configChanged:
            // Handled by the debounced config-reload pipeline in setupWatcher().
            break

        case .mustRescan:
            rescanAllSessions()
        }
    }

    private let deltaTracker = DeltaTracker()

    private func scanForRealtimeSecrets(url: URL, sessionId: String, projectId: String) async {
        guard realtimeSecretScanEnabled else { return }
        guard let lines = deltaTracker.readDelta(of: url) else { return }

        let findings = await linterService.scanLinesForSecrets(lines)
        guard !findings.isEmpty else { return }

        let title = sessionsByProject[projectId]?
            .first(where: { $0.id == sessionId })?.title ?? sessionId
        let isSubagent = url.pathComponents.contains("subagents")

        for finding in findings {
            let masked = ConfigLinterService.maskSecret(finding.matchedText)
            guard !alertedSecrets.contains(masked) else { continue }
            alertedSecrets.append(masked)
            if alertedSecrets.count > Self.alertedSecretsCap {
                alertedSecrets.removeFirst(alertedSecrets.count - Self.alertedSecretsCap)
            }

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
        hasActiveSession = allSessionsWithProjects.contains { pair in
            guard let date = ISO8601.parse(pair.session.lastTimestamp) else { return false }
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

            self.projects = scannedProjects
            self.sessionsByProject = scannedSessions
            self.recomputeAnalytics(rebaselineCostLedger: true)
            await self.recomputeDataCoverage()
            await self.loadCowork(rebaselineCostLedger: true)
        }
    }

    /// Recomputes the local data-coverage summary shown in the Analytics header.
    /// Kept separate from `recomputeAnalytics()` (which fires on every time-range
    /// change) because coverage only shifts when the session set or settings.json
    /// retention change.
    func recomputeDataCoverage() async {
        let history = await timelineService.loadEntries(since: nil, limit: nil)
        let ext = await configService.loadExtendedConfig()
        let knownIds = Set(sessionsByProject.values.flatMap { $0.map(\.id) })
        let oldest = sessionsByProject.values.flatMap { $0 }
            .map(\.firstTimestamp).filter { !$0.isEmpty }.min()
        dataCoverage = DataCoverage.compute(
            historyEntries: history,
            knownSessionIds: knownIds,
            cleanupPeriodDays: ext.cleanupPeriodDays,
            oldestFirstTimestamp: oldest
        )
    }

    func recomputeAnalytics(rebaselineCostLedger: Bool = false) {
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

        let baseData = AnalyticsEngine.compute(
            sessions: sessions,
            pricingTable: pricingTable,
            from: from,
            to: to
        )

        // Cowork cost is only attached when no project filter is active —
        // Cowork's project namespace doesn't overlap with CLI projects, so
        // mixing them under a filtered view would imply a relationship that
        // doesn't exist.
        if selectedAnalyticsProjectId == nil {
            let (coworkCost, hasUnknown) = AnalyticsEngine.computeCoworkCost(
                sessions: coworkSessions,
                parsedByID: coworkParsedSessionsByID,
                pricingTable: pricingTable,
                from: from,
                to: to
            )
            analyticsData = baseData.merging(coworkCost: coworkCost, hasUnknownModel: hasUnknown)
        } else {
            analyticsData = baseData
        }

        // Also recompute sidebar analytics (all projects, 30d)
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())
        sidebarAnalyticsData = AnalyticsEngine.compute(
            sessions: allSessionsWithProjects,
            pricingTable: pricingTable,
            from: thirtyDaysAgo,
            to: nil
        )

        evaluateCostAlerts(rebaselineLedger: rebaselineCostLedger)
    }

    /// Cached analytics for the sidebar (always all projects, 30d, for cost ranking).
    /// Recomputed only when recomputeAnalytics() is called, not on every view access.
    var sidebarAnalyticsData: AnalyticsData = .empty

    private func evaluateCostAlerts(rebaselineLedger: Bool) {
        guard !isLoading, let costAlertService else { return }

        let all = allSessionsWithProjects.map(\.session) + coworkSummaries
        var cumulativeCost = 0.0
        var cumulativeTokens = 0
        for session in all {
            cumulativeCost += session.estimatedCost
            cumulativeTokens += session.totalInputTokens + session.totalOutputTokens
        }

        let now = Date()
        let dayKey = Self.localDayFormatter.string(from: now)
        let monthKey = String(dayKey.prefix(7))
        let today = Self.dayTotals(sessions: all, dayKey: dayKey)
        let month = Self.monthTotals(sessions: all, monthKey: monthKey)

        costAlertService.evaluate(
            snapshot: CostSnapshot(
                cumulativeCost: cumulativeCost,
                cumulativeTokens: cumulativeTokens,
                recentSessions: Self.recentSessionFigures(sessions: all, now: now),
                todayCost: today.cost,
                todayTokens: today.tokens,
                monthCost: month.cost,
                monthTokens: month.tokens,
                dayKey: dayKey,
                monthKey: monthKey
            ),
            rebaselineLedger: rebaselineLedger
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
            self.selectedSession = cached
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
            self.selectedSession = session
        } catch {
            // Handle error
        }
    }

    // MARK: - Plans

    func loadPlans() async {
        plansLoading = true
        let loaded = await plansService.loadPlans()
        self.plans = loaded
        self.plansLoading = false
    }

    func loadPlanDetail(filename: String) async {
        let detail = await plansService.loadPlanDetail(filename: filename)
        self.selectedPlanDetail = detail
    }

    // MARK: - Timeline

    func loadTimeline() async {
        timelineLoading = true
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())
        let loaded = await timelineService.loadEntries(since: sevenDaysAgo)
        self.timelineEntries = loaded
        self.timelineLoading = false
    }

    // MARK: - Config (hooks, commands, MCPs, memory)

    func loadMemoryFiles(projectId: String?) async {
        let memory = await configService.loadMemoryFiles(projectId: projectId)
        self.memoryFiles = memory
    }

    // MARK: - Config Lint

    func runConfigLintIfNeeded(projectId: String?) async {
        guard !lintResultsValid else { return }
        await runConfigLint(projectId: projectId)
    }

    func runConfigLint(projectId: String?) async {
        lintLoading = true
        secretScanLoading = false

        let sessions: [SessionSummary]
        if let projectId {
            sessions = sessionsByProject[projectId] ?? []
        } else {
            sessions = sessionsByProject.values.flatMap { $0 }
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

        self.lintResults = phase1Results
        self.lintSummary = phase1Summary
        self.lintLoading = false
        self.secretScanLoading = true

        // Phase 2 (slow): secret scanning in background
        let secretResults = await linterService.lintSessionSecrets(sessions, claudeDir: claudeDir)

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

    func loadConfig(projectId: String?) async {
        configLoading = true
        let projectPaths = projects.map { (name: $0.name, path: $0.path) }
        let hooks = await configService.loadHooks(projectPaths: projectPaths)
        let cmds = await configService.loadCommands()
        let skls = await configService.loadSkills()
        let projectPath = projectId.flatMap { id in projects.first(where: { $0.id == id })?.path }
        let mcps = await configService.loadMcpServers(projectPath: projectPath)
        let memory = await configService.loadMemoryFiles(projectId: projectId)
        let extended = await configService.loadExtendedConfig()
        let loadedThemes = await configService.loadThemes()
        let loadedPlugins = await configService.loadPlugins()
        self.hookGroups = hooks
        self.commands = cmds
        self.skills = skls
        self.mcpServers = mcps
        self.memoryFiles = memory
        self.extendedConfig = extended
        self.themes = loadedThemes
        self.plugins = loadedPlugins
        self.configLoading = false
    }

    /// Load the plugin inventory in isolation, for the Plugins rail's on-demand
    /// load. Cheaper than a full loadConfig() when only the plugin list is needed.
    func loadPlugins() async {
        self.plugins = await configService.loadPlugins()
    }

    // MARK: - Subagent Tree

    func loadSubagentTree(sessionId: String, projectId: String) async {
        let fm = FileManager.default
        let subagentsDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(projectId)
            .appendingPathComponent(sessionId)
            .appendingPathComponent("subagents")

        guard fm.fileExists(atPath: subagentsDir.path) else {
            self.subagentTree = nil
            return
        }

        do {
            let subFiles = try fm.contentsOfDirectory(atPath: subagentsDir.path)
                .filter { $0.hasSuffix(".jsonl") }

            var subagentSummaries: [SessionSummary] = []
            for file in subFiles {
                let subId = String(file.dropLast(6))
                let url = subagentsDir.appendingPathComponent(file)
                do {
                    let summary = try await parser.parseMetadata(
                        url: url,
                        sessionId: subId,
                        pricingTable: pricingTable
                    )
                    subagentSummaries.append(summary)
                } catch {
                    NSLog("[Claudoscope] Subagent: failed to parse %@: %@",
                          url.path, error.localizedDescription)
                }
            }

            if let parentSessions = sessionsByProject[projectId],
               let parentSummary = parentSessions.first(where: { $0.id == sessionId }) {
                let tree = ObservabilityAnalyzer.buildSubagentTree(
                    parentSession: parentSummary,
                    subagentSummaries: subagentSummaries
                )
                self.subagentTree = tree
            } else {
                self.subagentTree = nil
            }
        } catch {
            self.subagentTree = nil
        }
    }

    func hasSubagentFiles(sessionId: String, projectId: String) -> Bool {
        let subagentsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(projectId)
            .appendingPathComponent(sessionId)
            .appendingPathComponent("subagents")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: subagentsDir.path) else {
            return false
        }
        return files.contains { $0.hasSuffix(".jsonl") }
    }
}

// MARK: - DeltaTracker

/// Thread-safe tracker for incremental file reads.
/// Keeps per-URL offsets so each call returns only new lines since the last read.
private final class DeltaTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var offsets: [URL: UInt64] = [:]

    func readDelta(of url: URL) -> [String]? {
        lock.lock()
        defer { lock.unlock() }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let fileSize = handle.seekToEndOfFile()
        let previousOffset = offsets[url] ?? 0

        if previousOffset == 0 || previousOffset > fileSize {
            let tailBytes: UInt64 = min(fileSize, 131_072)
            let tailOffset = fileSize > tailBytes ? fileSize - tailBytes : 0
            handle.seek(toFileOffset: tailOffset)
            guard let data = try? handle.readToEnd(),
                  let text = String(data: data, encoding: .utf8) else {
                offsets[url] = tailOffset
                return nil
            }
            offsets[url] = tailOffset + UInt64(data.count)
            let lines = text.components(separatedBy: "\n")
            return tailOffset > 0 ? Array(lines.dropFirst().suffix(50)) : Array(lines.suffix(50))
        }

        guard fileSize > previousOffset else { return nil }

        handle.seek(toFileOffset: previousOffset)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }

        // Resume from where this read actually ended, not from the pre-read
        // EOF snapshot, so any bytes appended during readToEnd() aren't skipped.
        offsets[url] = previousOffset + UInt64(data.count)

        if offsets.count > 200 {
            let fm = FileManager.default
            for key in offsets.keys where !fm.fileExists(atPath: key.path) {
                offsets.removeValue(forKey: key)
            }
        }

        let lines = text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return lines.isEmpty ? nil : lines
    }
}

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

    // Global project + date filter (sessions/tools/timeline/plans rails only,
    // sidebar-driven, persists across rail switches). Deliberately separate
    // from the analytics fields above so the two never entangle.
    var globalFilterProjectId: String? = nil  // nil = all projects
    var globalFilterRange: AnalyticsTimeRange = .all
    var globalFilterCustomFrom: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    var globalFilterCustomTo: Date = Date()
    var isLoading: Bool = true
    /// True while the background reconcile pass diffs disk against the summary
    /// cache and re-parses changed files. Gates cost-alert evaluation (alerts
    /// must only ever see complete data) and the scan banner on warm launches.
    var isReconciling: Bool = false
    var scanSessionsProcessed: Int = 0
    var scanSessionsTotal: Int = 0
    var selectedSession: ParsedSession?

    /// One-shot rail navigation requested from outside the dashboard window
    /// (e.g. the menu bar popover's Settings button). FullWindowView observes
    /// this, switches to the requested rail, then clears it back to nil.
    var requestedRail: RailItem?

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

    // Canon data (per-project decision records; read-only viewer). canonData
    // holds the currently-viewed project's records; canonLoadedProjectId lets the
    // session-event piggyback know which project's canon to refresh live.
    var canonData: CanonData?
    var canonDetectedProjectIds: Set<String> = []
    private var canonLoadedProjectId: String?

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

    // File changes data (session-detail Files tab). fileChangeSet.sessionKey
    // identifies which session it belongs to; the view ignores a mismatch.
    var fileChangeSet: FileChangeSet?
    var fileChangesLoading: Bool = false
    var fileDiskStates: [String: FileDiskState] = [:]

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
    // Session lifecycle notifications: owned by the app, fed spool events and
    // per-session activity from handleFileChange.
    @ObservationIgnored var sessionNotificationService: SessionNotificationService?
    // Canon: owned by the app. The lint pipeline consults it for per-project
    // opt-in gating and the bundled protocol version.
    @ObservationIgnored var canonService: CanonService?
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
    /// Persistent summary cache. nil when SQLite is unavailable (corruption
    /// recovery failed twice), in which case every scan degrades to the
    /// full-parse behavior this cache replaced.
    @ObservationIgnored private var summaryStore: SessionSummaryStore?
    /// The in-flight scan/reconcile pipeline. Rescans cancel-and-AWAIT it
    /// before recomputing global keys so a straggler batch upsert can never
    /// land after a global-key wipe and resurrect stale-priced rows.
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    private let watcher: ClaudeFileWatcher
    private let plansService: PlansService
    private let timelineService: TimelineService
    private let configService: ConfigService
    private let linterService = ConfigLinterService()
    private let fileChangesService = FileChangesService()
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

    var globalFilterActive: Bool {
        globalFilterProjectId != nil || globalFilterRange != .all
    }

    private var globalFilterDateBounds: (from: Date?, to: Date?) {
        globalFilterRange.dateRange(customFrom: globalFilterCustomFrom, customTo: globalFilterCustomTo)
    }

    private func withinGlobalFilterDateBounds(_ date: Date?) -> Bool {
        let bounds = globalFilterDateBounds
        guard bounds.from != nil || bounds.to != nil else { return true }
        guard let date else { return false }
        if let from = bounds.from, date < from { return false }
        if let to = bounds.to, date >= to { return false }
        return true
    }

    /// Projects and sessions narrowed by the global filter. Sessions/Tools
    /// sidebars read these instead of `projects`/`sessionsByProject` directly;
    /// the base collections stay untouched so the popover is unaffected.
    var filteredProjects: [Project] {
        guard globalFilterActive else { return projects }
        return projects.filter { project in
            (globalFilterProjectId == nil || globalFilterProjectId == project.id) &&
            !(filteredSessionsByProject[project.id] ?? []).isEmpty
        }
    }

    var filteredSessionsByProject: [String: [SessionSummary]] {
        guard globalFilterActive else { return sessionsByProject }
        var result: [String: [SessionSummary]] = [:]
        for (projectId, sessions) in sessionsByProject {
            if let selected = globalFilterProjectId, selected != projectId { continue }
            let kept = sessions.filter { withinGlobalFilterDateBounds(ISO8601.parse($0.lastTimestamp)) }
            if !kept.isEmpty { result[projectId] = kept }
        }
        return result
    }

    var filteredPlans: [PlanSummary] {
        guard globalFilterActive else { return plans }
        let selectedProjectName = globalFilterProjectId.flatMap { id in
            projects.first(where: { $0.id == id })?.name
        }
        return plans.filter { plan in
            if let selectedProjectName {
                guard let hint = plan.projectHint,
                      hint.localizedCaseInsensitiveContains(selectedProjectName) else { return false }
            }
            return withinGlobalFilterDateBounds(plan.createdAt)
        }
    }

    var filteredTimelineEntries: [HistoryEntry] {
        guard globalFilterActive else { return timelineEntries }
        return timelineEntries.filter { entry in
            if let selected = globalFilterProjectId {
                let matchesProjectId = entry.projectId == selected
                let matchesProjectPath = entry.project?.localizedCaseInsensitiveContains(selected) ?? false
                guard matchesProjectId || matchesProjectPath else { return false }
            }
            return withinGlobalFilterDateBounds(entry.timestamp)
        }
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

    /// A session counts as "active" if its last activity was within this many
    /// seconds. Shared by the Active Sessions card (< threshold), the menu bar
    /// dot (`checkActiveSession`), and `recentSessions` (>= threshold) so the
    /// active/recent boundary can never drift out of sync.
    nonisolated static let activeThreshold: TimeInterval = 60

    /// Recent sessions (last 3, any date, CLI + Cowork). Subagents are filtered
    /// out — their UUID titles would push real top-level sessions out of the
    /// popover's list. Currently-active sessions are excluded too: they already
    /// show in the Active Sessions card, so Recent complements it, never mirrors it.
    var recentSessions: [SessionSummary] {
        let now = Date()
        return Array(
            (allSessionsWithProjects.map(\.session) + coworkSummaries)
                .filter { !$0.isSubagent }
                .filter { session in
                    guard let date = ISO8601.parse(session.lastTimestamp) else { return true }
                    return now.timeIntervalSince(date) >= Self.activeThreshold
                }
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

        // Canon liveness (hybrid): canon files live in the repo working tree,
        // outside the watched ~/.claude/ tree, so they can't be watched directly.
        // Instead, piggyback on session events — when a session in the currently
        // viewed canon project updates (exactly when Claude appends records),
        // refresh that project's records. projectId is derived off the publish
        // thread; the loaded-project check runs on main to avoid a data race.
        watcher.changes
            .compactMap { change -> String? in
                switch change {
                case .sessionUpdated(let url), .sessionCreated(let url):
                    return Self.projectId(for: url)
                default:
                    return nil
                }
            }
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] projectId in
                guard let self else { return }
                Task {
                    if self.canonLoadedProjectId == projectId {
                        await self.loadCanon(projectId: projectId)
                    }
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
        scanTask = Task {
            await self.runScanPipeline(hydrateFirst: true)
        }
    }

    /// The launch/rescan pipeline: open the summary cache, apply global
    /// invalidation keys, hydrate the UI from cached rows (launch only), then
    /// reconcile disk against the cache in the background, parsing only
    /// changed files. With no cache (open failure) the reconcile degenerates
    /// to the full parse this app always did.
    private func runScanPipeline(hydrateFirst: Bool) async {
        if summaryStore == nil {
            summaryStore = SessionSummaryStore.open(at: SessionSummaryStore.defaultURL())
        }

        scanSessionsProcessed = 0
        scanSessionsTotal = 0

        // Global keys: any mismatch (parser version bump, pricing rates or
        // provider/region change, timezone change) wipes all cached rows so
        // the reconcile below reparses everything.
        if let store = summaryStore {
            let keys = SessionSummaryStore.GlobalCacheKeys(
                parserVersion: SessionParser.parserVersion,
                pricingKey: PricingTables.cacheKey(provider: pricingProvider, region: pricingRegion),
                tzIdentifier: TimeZone.current.identifier
            )
            do {
                let wiped = try await store.checkAndApplyGlobalKeys(keys)
                if wiped {
                    NSLog("[Claudoscope] SummaryCache: global keys changed, cache wiped for reindex")
                }
            } catch {
                NSLog("[Claudoscope] SummaryCache: global key check failed: %@", error.localizedDescription)
            }
        }

        // Hydrate: first paint from SQLite before any JSONL is parsed. Only
        // on launch; a rescan already has a populated in-memory index.
        if hydrateFirst, let store = summaryStore {
            let hydrateStart = Date()
            do {
                let (rows, undecodable) = try await store.fetchAllForHydration()
                if !undecodable.isEmpty {
                    // A model field changed without a parserVersion bump.
                    // Drop the rows so they become plain misses below.
                    try? await store.delete(filePaths: undecodable)
                    NSLog("[Claudoscope] SummaryCache: dropped %d undecodable rows", undecodable.count)
                }
                if !rows.isEmpty {
                    var grouped: [String: [SessionSummary]] = [:]
                    for (projectDir, summary) in rows {
                        grouped[projectDir, default: []].append(summary)
                    }
                    for key in grouped.keys {
                        grouped[key]?.sort(by: ProjectScanner.sessionOrder)
                    }
                    let projectsDir = claudeDir.appendingPathComponent("projects")
                    var hydratedProjects: [Project] = grouped.map { dirName, sessions in
                        Project(
                            id: dirName,
                            name: decodeProjectName(dirName),
                            path: projectsDir.appendingPathComponent(dirName).path,
                            sessionCount: sessions.count
                        )
                    }
                    hydratedProjects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

                    // isReconciling BEFORE the recompute: cost alerts must not
                    // evaluate against hydrated (possibly stale) totals. They
                    // run exactly once, at pipeline end, on complete data.
                    self.isReconciling = true
                    self.projects = hydratedProjects
                    self.sessionsByProject = grouped
                    self.isLoading = false
                    self.checkActiveSession()
                    self.recomputeAnalytics()
                    Task { await self.recomputeDataCoverage() }
                    NSLog("[Claudoscope] SummaryCache: hydrated %d sessions in %.0f ms",
                          rows.count, Date().timeIntervalSince(hydrateStart) * 1000)
                }
            } catch {
                NSLog("[Claudoscope] SummaryCache: hydration failed (%@), falling back to full scan",
                      error.localizedDescription)
            }
        }

        // Cold path (no rows) keeps isLoading = true, so launch UX is
        // unchanged; rescans need the flag for the banner and alert gate.
        self.isReconciling = true

        let scanner = ProjectScanner(
            claudeDir: claudeDir,
            parser: parser,
            pricingTable: pricingTable
        )
        let reconcileStart = Date()
        let liveKeys = await scanner.reconcile(
            store: summaryStore,
            onProgress: { [weak self] processed, total in
                self?.scanSessionsProcessed = processed
                self?.scanSessionsTotal = total
            },
            applyDelta: { [weak self] delta in
                guard let self else { return }
                for upsert in delta.upserts {
                    self.applySummary(upsert.summary, projectId: upsert.projectDir)
                }
                for deletion in delta.deletions {
                    self.removeSummary(projectId: deletion.projectDir, sessionId: deletion.sessionId)
                }
            }
        )

        if Task.isCancelled {
            // A rescan superseded this run; it owns the flag transitions now.
            return
        }

        // Ghost purge: in-memory entries with neither a file nor a cache row
        // (e.g. watcher inserts made while the cache was unavailable).
        for (projectId, sessions) in sessionsByProject {
            for session in sessions
            where !liveKeys.contains(.init(projectDir: projectId, sessionId: session.id)) {
                removeSummary(projectId: projectId, sessionId: session.id)
            }
        }

        // Finalize: one sort pass and fresh session counts.
        let projectsDir = claudeDir.appendingPathComponent("projects")
        var finalProjects: [Project] = []
        for (projectId, var sessions) in sessionsByProject {
            sessions.sort(by: ProjectScanner.sessionOrder)
            sessionsByProject[projectId] = sessions
            finalProjects.append(Project(
                id: projectId,
                name: decodeProjectName(projectId),
                path: projectsDir.appendingPathComponent(projectId).path,
                sessionCount: sessions.count
            ))
        }
        finalProjects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        self.projects = finalProjects

        if let store = summaryStore {
            try? await store.setLastFullScanAt(Date())
        }

        NSLog("[Claudoscope] SummaryCache: reconcile finished in %.0f ms (%d changed of %d live files)",
              Date().timeIntervalSince(reconcileStart) * 1000, scanSessionsTotal, liveKeys.count)

        self.isReconciling = false
        self.isLoading = false
        self.checkActiveSession()
        // Rebaseline ALWAYS: on a warm launch the reconcile delta can be a
        // week of appends, which the rolling spend ledger would misread as a
        // burst; on a cold launch the first observe self-baselines anyway.
        self.recomputeAnalytics(rebaselineCostLedger: true)
        await self.recomputeDataCoverage()
    }

    private func handleFileChange(_ change: FileChange) async {
        switch change {
        case .sessionUpdated(let url), .sessionCreated(let url):
            let sessionId = url.deletingPathExtension().lastPathComponent
            let projectId = Self.projectId(for: url)

            // Invalidate cache
            await cache.invalidate(sessionId)

            // Fingerprint BEFORE parsing: bytes appended mid-parse would
            // otherwise be recorded as already cached. A pre-parse identity is
            // at worst stale, which self-heals on the next reconcile.
            let identity = SessionSummaryStore.statIdentity(for: url)

            do {
                let summary = try await parser.parseMetadata(
                    url: url,
                    sessionId: sessionId,
                    pricingTable: pricingTable
                )

                // applySummary re-reads state after the await so concurrent
                // handlers (or a rescan) that completed during the suspension
                // don't get clobbered.
                self.applySummary(summary, projectId: projectId)

                // Give the notification service the session title (subagents
                // skipped inside) so "your turn" and block banners can show it.
                self.sessionNotificationService?.noteActivity(
                    sessionId: summary.id,
                    isSubagent: summary.isSubagent,
                    title: summary.title
                )

                self.checkActiveSession()
                self.recomputeAnalytics()
                // A brand-new transcript can close a coverage gap (a previously
                // missing history session now has a file); recompute on create
                // only — plain updates don't change the known-id set.
                if case .sessionCreated = change {
                    await self.recomputeDataCoverage()
                }

                // Write-through to the summary cache. Failures are non-fatal:
                // memory stays authoritative and the next reconcile heals.
                if let store = summaryStore, let identity {
                    do {
                        let record = try SessionSummaryRecord.make(
                            summary: summary,
                            filePath: url.path,
                            projectDir: projectId,
                            identity: identity
                        )
                        try await store.upsert([record])
                    } catch {
                        NSLog("[Claudoscope] Watcher: cache upsert failed for %@: %@",
                              sessionId, error.localizedDescription)
                    }
                }
            } catch {
                NSLog("[Claudoscope] Watcher: failed to parse session %@ in project %@: %@",
                      sessionId, projectId, error.localizedDescription)
            }

            // Invalidate lint cache so next Config Health visit rescans
            self.lintResultsValid = false

            // Real-time secret scan: check last 50 lines for secrets
            await scanForRealtimeSecrets(url: url, sessionId: sessionId, projectId: projectId)

        case .sessionDeleted(let url):
            let sessionId = url.deletingPathExtension().lastPathComponent
            let projectId = Self.projectId(for: url)

            await cache.invalidate(sessionId)
            self.removeSummary(projectId: projectId, sessionId: sessionId)
            if let store = summaryStore {
                try? await store.delete(filePaths: [url.path])
            }

            self.lintResultsValid = false
            self.checkActiveSession()
            self.recomputeAnalytics()
            // The known-id set shrank; the coverage badge must reflect it.
            await self.recomputeDataCoverage()

        case .notificationEvent(let url):
            sessionNotificationService?.handleSpoolFile(url)

        case .configChanged:
            // Handled by the debounced config-reload pipeline in setupWatcher().
            break

        case .mustRescan:
            rescanAllSessions()
        }
    }

    /// Project directory id for a session file: the path component right
    /// after "projects" (subagent files live two levels deeper).
    nonisolated private static func projectId(for url: URL) -> String {
        let components = url.pathComponents
        if let idx = components.lastIndex(of: "projects"), idx + 1 < components.count {
            return components[idx + 1]
        }
        return url.deletingLastPathComponent().lastPathComponent
    }

    /// Insert-or-replace one summary in the in-memory index, creating its
    /// Project entry when needed. Shared by the watcher handler and the
    /// reconcile delta application; reads current state at call time, so it
    /// is safe after suspensions.
    private func applySummary(_ summary: SessionSummary, projectId: String) {
        var sessions = sessionsByProject[projectId] ?? []
        if let idx = sessions.firstIndex(where: { $0.id == summary.id }) {
            sessions[idx] = summary
        } else {
            sessions.insert(summary, at: 0)
        }
        sessionsByProject[projectId] = sessions

        if !projects.contains(where: { $0.id == projectId }) {
            let project = Project(
                id: projectId,
                name: decodeProjectName(projectId),
                path: claudeDir.appendingPathComponent("projects").appendingPathComponent(projectId).path,
                sessionCount: sessions.count
            )
            projects.append(project)
            projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    /// Remove one summary from the in-memory index, dropping the Project
    /// entry when its last session goes.
    private func removeSummary(projectId: String, sessionId: String) {
        guard var sessions = sessionsByProject[projectId] else { return }
        sessions.removeAll { $0.id == sessionId }
        if sessions.isEmpty {
            sessionsByProject.removeValue(forKey: projectId)
            projects.removeAll { $0.id == projectId }
        } else {
            sessionsByProject[projectId] = sessions
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
            return now.timeIntervalSince(date) < Self.activeThreshold
        }
    }

    /// Re-scan all sessions with the current pricing table (e.g. after pricing
    /// provider change) or after an FSEvents overflow. A pricing change
    /// mismatches the cache's pricing key, so the pipeline wipes and reparses
    /// everything (with progress); an overflow reconciles against matching
    /// keys, which is a cheap stat-everything diff.
    func rescanAllSessions() {
        Task {
            // Cancel-and-AWAIT before the pipeline recomputes global keys:
            // a straggler batch upsert landing after the wipe would resurrect
            // stale-priced rows.
            self.scanTask?.cancel()
            await self.scanTask?.value

            let pipeline = Task { await self.runScanPipeline(hydrateFirst: false) }
            self.scanTask = pipeline
            await pipeline.value
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
        guard !isLoading, !isReconciling, let costAlertService else { return }

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

    // MARK: - Canon

    /// Load the selected project's canon records + install status off disk.
    /// Records `canonLoadedProjectId` so the session-event piggyback knows which
    /// project to refresh live.
    func loadCanon(projectId: String?) async {
        let data = await configService.loadCanon(projectId: projectId)
        self.canonData = data
        self.canonLoadedProjectId = projectId
    }

    /// Recompute which known projects have canon artifacts on disk. Drives the
    /// Canon sidebar's "detected on disk" indicator.
    func refreshCanonDetection() async {
        let ids = projects.map(\.id)
        let detected = await configService.detectCanonProjects(projectIds: ids)
        self.canonDetectedProjectIds = detected
    }

    /// Install canon into one project and record the opt-in. Resolves the real
    /// repo path (Project.path is the session dir, not the working tree).
    @discardableResult
    func enableCanon(projectId: String) async throws -> CanonInstallResult {
        guard let canonService else { throw CanonInstallError.io("Canon service unavailable") }
        guard let realPath = await configService.realProjectPath(projectId) else {
            throw CanonInstallError.io("Project directory not found on disk")
        }
        let result = try await canonService.enable(projectId: projectId, projectPath: realPath)
        if canonLoadedProjectId == projectId { await loadCanon(projectId: projectId) }
        await refreshCanonDetection()
        return result
    }

    /// Remove the protocol rule for one project (records kept) and clear opt-in.
    /// If the repo path is gone, just drops the stale opt-in.
    func disableCanon(projectId: String) async throws {
        guard let canonService else { throw CanonInstallError.io("Canon service unavailable") }
        if let realPath = await configService.realProjectPath(projectId) {
            try await canonService.disable(projectId: projectId, projectPath: realPath)
        } else {
            canonService.forgetOptIn(projectId)
        }
        if canonLoadedProjectId == projectId { await loadCanon(projectId: projectId) }
        await refreshCanonDetection()
    }

    /// Bulk-enable canon across every known project. Projects whose repo path no
    /// longer exists on disk are skipped. Refreshes viewer + detection once at
    /// the end.
    func enableCanonForAllProjects() async -> CanonBulkResult {
        guard let canonService else { return CanonBulkResult() }
        var result = CanonBulkResult()
        for project in projects {
            guard let realPath = await configService.realProjectPath(project.id) else {
                result.skipped += 1
                continue
            }
            do {
                _ = try await canonService.enable(projectId: project.id, projectPath: realPath)
                result.succeeded += 1
            } catch {
                result.failed += 1
                result.failedNames.append(project.name)
            }
        }
        if let pid = canonLoadedProjectId { await loadCanon(projectId: pid) }
        await refreshCanonDetection()
        return result
    }

    /// Bulk-disable canon across every currently opted-in project. Records are
    /// kept on disk; only the protocol rule + opt-in are removed.
    func disableCanonForAllProjects() async -> CanonBulkResult {
        guard let canonService else { return CanonBulkResult() }
        var result = CanonBulkResult()
        let optedIn = projects.filter { canonService.isOptedIn($0.id) }
        for project in optedIn {
            if let realPath = await configService.realProjectPath(project.id) {
                do {
                    try await canonService.disable(projectId: project.id, projectPath: realPath)
                    result.succeeded += 1
                } catch {
                    result.failed += 1
                    result.failedNames.append(project.name)
                }
            } else {
                canonService.forgetOptIn(project.id)
                result.skipped += 1
            }
        }
        if let pid = canonLoadedProjectId { await loadCanon(projectId: pid) }
        await refreshCanonDetection()
        return result
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

        // Canon (CAN family): only for the selected project when it is opted in.
        if let projectId, let projectRoot, let canonService, canonService.isOptedIn(projectId) {
            let canonResults = await linterService.lintCanon(
                projectRoot: projectRoot,
                bundledProtocolVersion: canonService.bundledProtocolVersion
            )
            fastResults.append(contentsOf: canonResults)
        }

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

    // MARK: - File Changes (Files tab)

    /// Locator key for a session's Files-tab data. The view's .task(id:) and
    /// stale-guard use this exact key, so it can never diverge from what
    /// loadFileChanges stores (see FileChangesService.fileChangesLocator).
    func fileChangesKey(for session: ParsedSession) -> String {
        FileChangesService.fileChangesLocator(for: session, claudeDir: claudeDir).key
    }

    func loadFileChanges(for session: ParsedSession) async {
        let locator = FileChangesService.fileChangesLocator(for: session, claudeDir: claudeDir)
        fileChangesLoading = true
        defer { fileChangesLoading = false }
        do {
            let changeSet = try await fileChangesService.loadChangeSet(
                mainFileURL: locator.url,
                sessionKey: locator.key
            )
            // Disk states are re-checked on every activation, cache hit or not.
            let states = await fileChangesService.diskStates(for: changeSet)
            self.fileChangeSet = changeSet
            self.fileDiskStates = states
        } catch {
            if self.fileChangeSet?.sessionKey == locator.key {
                self.fileChangeSet = nil
                self.fileDiskStates = [:]
            }
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

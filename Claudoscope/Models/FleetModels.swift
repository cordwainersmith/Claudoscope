import Foundation

/// One running Claude Code process, as written by Claude Code itself to
/// `~/.claude/sessions/<pid>.json`. Undocumented format (2.1.280): every field
/// beyond pid and sessionId is optional so a shape change degrades to "less
/// detail", never to a decode failure. The sibling `<pid>.<sha>.key` files hold
/// per-process secrets and are never read.
struct RegistryEntry: Decodable, Sendable, Equatable, Identifiable {
    var id: Int { pid }
    let pid: Int
    let sessionId: String
    let cwd: String?
    let startedAt: Double?          // epoch ms
    let procStart: String?
    let version: String?
    let kind: String?               // "interactive" | "bg"
    let jobId: String?
    let name: String?
    let status: String?             // busy | idle | shell | waiting | ...
    let statusUpdatedAt: Double?    // epoch ms
    let updatedAt: Double?          // epoch ms
    let waitingFor: String?

    enum CodingKeys: String, CodingKey {
        case pid, sessionId, cwd, startedAt, procStart, version, kind, jobId, name
        case status, statusUpdatedAt, updatedAt, waitingFor
    }

    init(pid: Int, sessionId: String, cwd: String? = nil, startedAt: Double? = nil,
         procStart: String? = nil, version: String? = nil, kind: String? = nil,
         jobId: String? = nil, name: String? = nil, status: String? = nil,
         statusUpdatedAt: Double? = nil, updatedAt: Double? = nil, waitingFor: String? = nil) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.startedAt = startedAt
        self.procStart = procStart
        self.version = version
        self.kind = kind
        self.jobId = jobId
        self.name = name
        self.status = status
        self.statusUpdatedAt = statusUpdatedAt
        self.updatedAt = updatedAt
        self.waitingFor = waitingFor
    }

    var isBackground: Bool { kind == "bg" }
    var statusDate: Date? { statusUpdatedAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
    var startedDate: Date? { startedAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
    /// Last path component of the working directory, used as the terminal
    /// title needle. More precise than the decoded project name for worktrees.
    var cwdFolderName: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
}

enum FleetState: Equatable, Sendable, Hashable {
    case blockedOnPermission
    case waitingOnUser(reason: String)
    case working
    case idle
    case failed
    case done

    /// Attention order: what needs the user comes first.
    var sortRank: Int {
        switch self {
        case .blockedOnPermission: return 0
        case .waitingOnUser: return 1
        case .working: return 2
        case .idle: return 3
        case .failed: return 4
        case .done: return 5
        }
    }

    var label: String {
        switch self {
        case .blockedOnPermission: return "Blocked on permission"
        case .waitingOnUser: return "Waiting on you"
        case .working: return "Working"
        case .idle: return "Idle"
        case .failed: return "Failed"
        case .done: return "Done"
        }
    }

    var needsAttention: Bool { sortRank <= 1 }

    /// Stable identifier for filter pills (reasons vary per agent).
    var filterKey: String {
        switch self {
        case .blockedOnPermission: return "blocked"
        case .waitingOnUser: return "waiting"
        case .working: return "working"
        case .idle: return "idle"
        case .failed: return "failed"
        case .done: return "done"
        }
    }
}

/// The last hook event Claudoscope saw for a session, captured from the
/// Notification/Stop hook spool before the notification service drains it.
struct FleetHookEvent: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case permissionPrompt, elicitation, genericBlock, yourTurn }
    let kind: Kind
    let message: String?
    let receivedAt: Date
    let cwd: String?
}

/// One card on the Fleet board: a session joined with its live registry entry
/// (if the process is running) and its derived state.
struct FleetAgent: Identifiable, Sendable, Equatable {
    var id: String { summary.id }
    let summary: SessionSummary
    let registry: RegistryEntry?
    let state: FleetState
    /// When the current state began: registry statusUpdatedAt, hook receivedAt,
    /// or the transcript's last activity.
    let since: Date
    let isLive: Bool
    let isBackgroundJob: Bool
    let isBypass: Bool

    /// Terminal tab title needle: the registry cwd folder when live, else the
    /// decoded project folder name.
    var focusNeedle: String {
        registry?.cwdFolderName ?? decodeProjectName(summary.projectId)
    }

    var projectName: String {
        summary.isCowork ? "Cowork" : decodeProjectName(summary.projectId)
    }

    var branchLabel: String? {
        summary.worktreeBranch ?? summary.worktreeName ?? summary.gitBranch
    }

    var startedAt: Date {
        ISO8601.parse(summary.firstTimestamp) ?? registry?.startedDate ?? since
    }

    /// Lifetime average spend rate. Nil for sessions younger than five minutes,
    /// where one expensive first turn would read as an absurd hourly rate.
    func burnRatePerHour(now: Date) -> Double? {
        let end = isLive ? now : (ISO8601.parse(summary.lastTimestamp) ?? now)
        let hours = end.timeIntervalSince(startedAt) / 3600
        guard hours >= 5.0 / 60, summary.estimatedCost > 0 else { return nil }
        return summary.estimatedCost / hours
    }

    /// Share of prompt tokens served from cache.
    var cacheHitRate: Double? {
        let prompt = summary.totalInputTokens + summary.totalCacheReadTokens + summary.totalCacheCreationTokens
        guard prompt > 0 else { return nil }
        return Double(summary.totalCacheReadTokens) / Double(prompt)
    }
}

/// A one-shot request from outside the dashboard window (popover, hotkey,
/// notification tap) to select a session. Consumed next to `requestedRail`.
struct RequestedSelection: Equatable, Sendable {
    let projectId: String
    let sessionId: String
}

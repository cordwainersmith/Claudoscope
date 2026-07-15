import AppKit
import Foundation
import UserNotifications

/// Owns session lifecycle notifications (waiting / completed): configuration,
/// the installed hook, the spool ingest path, the per-session activity model,
/// and delivery via `UNUserNotificationCenter`. App-owned and driven by
/// `SessionStore` (spool events + activity), mirroring `CostAlertService`.
///
/// Deliberately sets NO `UNUserNotificationCenter` delegate: `CostAlertService`
/// already installs one whose `willPresent` presents every notification, and we
/// want no tap action, so relying on it keeps a single delegate. Construct this
/// service AFTER `CostAlertService` so that delegate exists.
@MainActor @Observable
final class SessionNotificationService {

    enum Kind: String {
        case waiting
        case completed
    }

    var config: NotificationConfig {
        didSet {
            guard config != oldValue else { return }
            persistConfig()
        }
    }

    private(set) var notificationsDenied = false

    @ObservationIgnored private let claudeDir: URL
    @ObservationIgnored private let installer: NotificationHookInstaller
    @ObservationIgnored private var activity: [String: SessionNotificationEngine.ActivitySnapshot] = [:]
    @ObservationIgnored private var sessionLabels: [String: String] = [:]
    @ObservationIgnored private var completedTimer: Timer?

    private static let configKey = "sessionNotificationConfig"
    private static let tickInterval: TimeInterval = 30
    private static let eventTTL: TimeInterval = 120
    private static let activityCap = 500

    private var spoolDir: URL { claudeDir.appendingPathComponent(NotificationHookInstaller.spoolDirName) }

    /// `UNUserNotificationCenter` traps in a non-bundled binary (swift run, SPM
    /// tests), so every notification path goes through this optional.
    private var notificationCenter: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier != nil ? UNUserNotificationCenter.current() : nil
    }

    var notificationsUnavailable: Bool { Bundle.main.bundleIdentifier == nil }

    init(claudeDir: URL, setInstallInProgress: @escaping @Sendable @MainActor (Bool) -> Void) {
        self.claudeDir = claudeDir
        self.config = Self.loadConfig()
        self.installer = NotificationHookInstaller(claudeDir: claudeDir, setInstallInProgress: setInstallInProgress)

        // Live-only: clear any events queued while the app was down, without
        // notifying, so a resolved prompt from an hour ago never surfaces.
        drainSpool()

        // Returning from System Settings reactivates the app; refresh so the
        // denied warning clears as soon as the user flips notifications on.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.config.masterEnabled else { return }
                self.refreshAuthorizationStatus()
            }
        }

        startCompletedTimer()
    }

    // MARK: - Enable / disable (drives hook install + permission)

    /// True when the user already has a `session-notify.sh` hook that would
    /// double-notify. The Settings UI uses this to confirm replacement.
    func hasConflictingHook() async -> Bool {
        await installer.detectExistingSessionNotify()
    }

    func enable() async {
        requestNotificationPermission()
        do {
            try await installer.install()
            config.masterEnabled = true
        } catch {
            NSLog("[Claudoscope] Notification hook install failed: %@", "\(error)")
            config.masterEnabled = false
        }
    }

    func disable() async {
        config.masterEnabled = false
        do {
            try await installer.uninstall()
        } catch {
            NSLog("[Claudoscope] Notification hook uninstall failed: %@", "\(error)")
        }
        activity.removeAll()
        sessionLabels.removeAll()
        drainSpool()
    }

    // MARK: - Ingest (called by SessionStore)

    /// A spool file appeared. Parse, filter, dedupe, deliver, then delete. Any
    /// failure (unreadable, garbage, stale) is a silent no-op; the file is still
    /// removed so it can never be reprocessed.
    func handleSpoolFile(_ url: URL) {
        defer { try? FileManager.default.removeItem(at: url) }
        guard config.masterEnabled else { return }
        guard let data = try? Data(contentsOf: url),
              let event = SessionNotificationEngine.parseSpoolPayload(data) else { return }

        // Freshness guard (sleep/wake, backlog): ignore events older than the TTL.
        if let mtime = fileMTime(url), Date().timeIntervalSince(mtime) > Self.eventTTL { return }

        let isIdle = SessionNotificationEngine.isIdlePrompt(
            notificationType: event.notificationType,
            message: event.message
        )
        guard isIdle ? config.notifyOnIdle : config.notifyOnBlocks else { return }

        let projectId = event.transcriptPath.flatMap { Self.projectId(forTranscriptPath: $0) }

        // Dedupe: notify only on the transition INTO waiting. Repeated prompts
        // for the same session (permission re-fires ~every 60s) are suppressed
        // until real activity resumes and clears `waitingSince`.
        if var snap = activity[event.sessionId] {
            if snap.waitingSince != nil { return }
            snap.waitingSince = Date()
            activity[event.sessionId] = snap
        } else {
            activity[event.sessionId] = .init(
                spanSeconds: 0,
                lastActivityWall: Date(),
                projectId: projectId ?? "",
                firedCompleted: false,
                waitingSince: Date()
            )
        }

        guard shouldDeliver(projectId: projectId) else { return }
        let label = notificationLabel(sessionId: event.sessionId, projectId: projectId, cwd: event.cwd)
        postNotification(
            kind: .waiting,
            sessionId: event.sessionId,
            title: isIdle ? "Claude is waiting" : "Claude needs you",
            subtitle: label,
            body: event.message ?? "Waiting for your input."
        )
    }

    /// Record activity for a session. Subagents are skipped so their UUID-titled
    /// files never fire "completed". New activity re-arms completion and clears
    /// any waiting state (the block was resolved).
    func noteActivity(
        sessionId: String,
        isSubagent: Bool,
        projectId: String,
        title: String,
        firstTimestamp: String,
        lastTimestamp: String
    ) {
        guard config.masterEnabled, !isSubagent else { return }
        let span = Self.spanSeconds(first: firstTimestamp, last: lastTimestamp)
        if var snap = activity[sessionId] {
            snap.spanSeconds = span
            snap.lastActivityWall = Date()
            snap.projectId = projectId
            snap.firedCompleted = false
            snap.waitingSince = nil
            activity[sessionId] = snap
        } else {
            activity[sessionId] = .init(
                spanSeconds: span,
                lastActivityWall: Date(),
                projectId: projectId,
                firedCompleted: false,
                waitingSince: nil
            )
        }
        if !title.isEmpty { sessionLabels[sessionId] = title }
        pruneActivity()
    }

    // MARK: - Completed timer

    private func startCompletedTimer() {
        completedTimer?.invalidate()
        completedTimer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
    }

    private func onTick() {
        sweepSpool()
        guard config.masterEnabled, config.notifyOnCompleted else { return }
        let now = Date()
        for id in SessionNotificationEngine.completedSessionsToFire(activity, now: now) {
            guard var snap = activity[id] else { continue }
            snap.firedCompleted = true   // fire at most once per run, even if suppressed
            activity[id] = snap
            guard shouldDeliver(projectId: snap.projectId.isEmpty ? nil : snap.projectId) else { continue }
            let label = notificationLabel(sessionId: id, projectId: snap.projectId, cwd: nil)
            postNotification(
                kind: .completed,
                sessionId: id,
                title: "Session complete",
                subtitle: label,
                body: "Finished after a long run."
            )
        }
    }

    // MARK: - Delivery

    private func shouldDeliver(projectId: String?) -> Bool {
        guard config.masterEnabled else { return false }
        if let projectId, config.mutedProjectIds.contains(projectId) { return false }
        if config.isInQuietHours(Date()) { return false }
        return true
    }

    private func postNotification(kind: Kind, sessionId: String, title: String, subtitle: String?, body: String) {
        guard let center = notificationCenter else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle, !subtitle.isEmpty { content.subtitle = subtitle }
        content.body = body
        content.sound = config.soundEnabled ? Self.sound(for: kind) : nil
        // Stable identifier: a repeat for the same (kind, session) replaces the
        // existing banner in Notification Center rather than stacking.
        let request = UNNotificationRequest(
            identifier: "claudoscope-\(kind.rawValue)-\(sessionId)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    private static func sound(for kind: Kind) -> UNNotificationSound {
        switch kind {
        case .waiting: return UNNotificationSound(named: UNNotificationSoundName("Funk.aiff"))
        case .completed: return UNNotificationSound(named: UNNotificationSoundName("Glass.aiff"))
        }
    }

    func requestNotificationPermission() {
        guard let center = notificationCenter else { return }
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.notificationsDenied = !granted }
        }
    }

    func refreshAuthorizationStatus() {
        guard let center = notificationCenter else { return }
        center.getNotificationSettings { [weak self] settings in
            let denied = settings.authorizationStatus == .denied
            Task { @MainActor in self?.notificationsDenied = denied }
        }
    }

    /// Deep link to System Settings > Notifications, scrolled to this app.
    func openSystemNotificationSettings() {
        var urlString = "x-apple.systempreferences:com.apple.preference.notifications"
        if let bundleId = Bundle.main.bundleIdentifier {
            urlString += "?id=\(bundleId)"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Spool housekeeping

    private func drainSpool() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: spoolDir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "json" { try? fm.removeItem(at: f) }
    }

    private func sweepSpool() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: spoolDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-Self.eventTTL)
        for f in files where f.pathExtension == "json" {
            if let m = fileMTime(f), m < cutoff { try? fm.removeItem(at: f) }
        }
    }

    // MARK: - Helpers

    private func pruneActivity() {
        guard activity.count > Self.activityCap else { return }
        let overflow = activity.count - Self.activityCap
        let victims = activity
            .sorted { $0.value.lastActivityWall < $1.value.lastActivityWall }
            .prefix(overflow)
            .map(\.key)
        for id in victims {
            activity.removeValue(forKey: id)
            sessionLabels.removeValue(forKey: id)
        }
    }

    /// Notification subtitle: the project/repo folder name (same decoder the
    /// sidebar uses), with a meaningful session title overlaid as "Title (folder)".
    /// The raw 8-char session-id fallback is never shown. Mirrors the original
    /// session-notify.sh, which labeled by folder and only upgraded on /rename.
    private func notificationLabel(sessionId: String, projectId: String?, cwd: String?) -> String {
        let folder = projectId.flatMap { $0.isEmpty ? nil : Self.projectLabel(fromProjectId: $0) }
            ?? cwd.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).lastPathComponent }
            ?? "a session"
        return Self.composeLabel(title: sessionLabels[sessionId], folder: folder, sessionId: sessionId)
    }

    /// "Title (folder)" when the session has a real title, else just the folder.
    /// Drops a title that is the 8-char session-id fallback or equals the folder.
    nonisolated static func composeLabel(title: String?, folder: String, sessionId: String) -> String {
        if let title, !title.isEmpty, title != String(sessionId.prefix(8)), title != folder {
            return "\(title) (\(folder))"
        }
        return folder
    }

    private func fileMTime(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    nonisolated static func spanSeconds(first: String, last: String) -> Double {
        guard let f = ISO8601.parse(first), let l = ISO8601.parse(last) else { return 0 }
        return max(0, l.timeIntervalSince(f))
    }

    /// Project directory id for a transcript path: the component right after
    /// "projects" (mirrors `SessionStore.projectId(for:)`).
    nonisolated static func projectId(forTranscriptPath path: String) -> String? {
        let comps = URL(fileURLWithPath: path).pathComponents
        if let idx = comps.lastIndex(of: "projects"), idx + 1 < comps.count {
            return comps[idx + 1]
        }
        return nil
    }

    /// Human label from an encoded project dir id like
    /// "-Users-liranb-projects-Claudoscope" -> "Claudoscope".
    /// Human folder name for an encoded project id, via the app's shared decoder
    /// (correctly rejoins hyphenated folder names like "fix-okta-callback-race").
    nonisolated static func projectLabel(fromProjectId id: String) -> String {
        decodeProjectName(id)
    }

    // MARK: - Persistence

    private func persistConfig() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.configKey)
        }
    }

    private static func loadConfig() -> NotificationConfig {
        guard let data = UserDefaults.standard.data(forKey: configKey),
              let decoded = try? JSONDecoder().decode(NotificationConfig.self, from: data) else {
            return .default
        }
        return decoded
    }
}
